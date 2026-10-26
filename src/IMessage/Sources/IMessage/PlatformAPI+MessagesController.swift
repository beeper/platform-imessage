import Foundation
import IMessageCore
import Logging

private let platformMessagesControllerLog = Logger(imessageLabel: "platform-api")

private typealias MessagesControllerEntry = UncheckedSendableBox<MessagesController>

private enum MessagesControllerCoordinatorError: Error {
    case cachedControllerInvalid
    case pendingControllerInvalidated
}

actor MessagesControllerCoordinator<Controller: AnyObject> {
    typealias MessagesControllerEntry = UncheckedSendableBox<Controller>

    private let createController: @Sendable (PlatformAPI.ReportErrorMessage?) async throws -> MessagesControllerEntry
    private let controllerIsValid: @Sendable (Controller) -> Bool
    private let disposeController: @Sendable (MessagesControllerEntry) async throws -> Void
    private var current: MessagesControllerEntry?
    // Concurrent callers share one in-flight construction.
    private var pendingController: Task<MessagesControllerEntry, Error>?
    private var pendingDisposal: Task<Void, Error>?

    init(
        create: @escaping @Sendable (PlatformAPI.ReportErrorMessage?) async throws -> MessagesControllerEntry,
        isValid: @escaping @Sendable (Controller) -> Bool,
        dispose: @escaping @Sendable (MessagesControllerEntry) async throws -> Void
    ) {
        createController = create
        controllerIsValid = isValid
        disposeController = dispose
    }

    func withController<T>(
        reportErrorMessage: PlatformAPI.ReportErrorMessage?,
        hasBeenDisposed: Protected<Bool>,
        forceInvalidate: Bool = false,
        _ action: @escaping @Sendable (Controller) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !hasBeenDisposed.read() else {
            throw ErrorMessage("PlatformAPI has been disposed")
        }
        if forceInvalidate {
            try await disposeCachedController()
        }

        for _ in 0..<30 {
            try Task.checkCancellation()
            let entry: MessagesControllerEntry
            do {
                entry = try await currentControllerEntry(
                    reportErrorMessage: reportErrorMessage,
                    hasBeenDisposed: hasBeenDisposed
                )
            } catch MessagesControllerCoordinatorError.pendingControllerInvalidated {
                try Task.checkCancellation()
                continue
            }

            do {
                let controllerIsValid = controllerIsValid
                return try await PlatformAPI.runOnMessagesControllerLane {
                    guard !hasBeenDisposed.read() else {
                        throw ErrorMessage("PlatformAPI has been disposed")
                    }
                    guard controllerIsValid(entry.value) else {
                        throw MessagesControllerCoordinatorError.cachedControllerInvalid
                    }
                    return try await action(entry.value)
                }
            } catch MessagesControllerCoordinatorError.cachedControllerInvalid {
                platformMessagesControllerLog.debug("disposing cached MessagesController because it became invalid")
                try await disposeIfCurrent(entry)
            }
        }
        throw ErrorMessage("MessagesController repeatedly invalid")
    }

    func disposeCachedController() async throws {
        if current == nil, pendingController == nil {
            try await waitForPendingDisposal()
            return
        }
        let entry = current
        let pendingController = pendingController
        current = nil
        self.pendingController = nil

        // Finish construction and disposal even if the caller is cancelled.
        // Publish this task before suspending so replacements wait for cleanup.
        let disposal = Task {
            if let pendingController {
                let created = try await pendingController.value
                try await disposeController(created)
            }

            if let entry {
                try await disposeController(entry)
            }
        }
        pendingDisposal = disposal
        defer {
            if pendingDisposal == disposal { pendingDisposal = nil }
        }
        try await disposal.value
    }

    private func waitForPendingDisposal() async throws {
        while let disposal = pendingDisposal {
            defer {
                if pendingDisposal == disposal { pendingDisposal = nil }
            }
            try await disposal.value
        }
    }
}

private final class MessageSendGate: Sendable {
    private let tail = Protected<Task<Void, Never>?>()

    func run<T>(_ operation: () async throws -> T) async throws -> T {
        let (released, release) = AsyncStream<Void>.makeStream()
        let previous = tail.withLock { tail in
            let previous = tail
            tail = Task {
                for await _ in released {}
            }
            return previous
        }
        defer { release.finish() }
        await previous?.value
        try Task.checkCancellation()
        return try await operation()
    }
}

private extension MessagesControllerCoordinator {
    func currentControllerEntry(
        reportErrorMessage: PlatformAPI.ReportErrorMessage?,
        hasBeenDisposed: Protected<Bool>
    ) async throws -> MessagesControllerEntry {
        try await waitForPendingDisposal()
        try Task.checkCancellation()
        guard !hasBeenDisposed.read() else {
            throw ErrorMessage("PlatformAPI has been disposed")
        }

        if let current {
            return current
        }

        let controllerTask = pendingController ?? startControllerCreation(reportErrorMessage: reportErrorMessage)
        return try await installPendingController(controllerTask, hasBeenDisposed: hasBeenDisposed)
    }

    private func startControllerCreation(reportErrorMessage: PlatformAPI.ReportErrorMessage?) -> Task<MessagesControllerEntry, Error> {
        let task = Task {
            try await createController(reportErrorMessage)
        }
        pendingController = task
        return task
    }

    private func installPendingController(
        _ controllerTask: Task<MessagesControllerEntry, Error>,
        hasBeenDisposed: Protected<Bool>
    ) async throws -> MessagesControllerEntry {
        do {
            let entry = try await controllerTask.value

            if let current, current.value === entry.value {
                return current
            }

            guard pendingController == controllerTask else {
                throw MessagesControllerCoordinatorError.pendingControllerInvalidated
            }

            guard !hasBeenDisposed.read() else {
                try await disposeCachedController()
                throw ErrorMessage("PlatformAPI has been disposed")
            }

            pendingController = nil
            current = entry
            return entry
        } catch {
            if pendingController == controllerTask {
                pendingController = nil
            }
            throw error
        }
    }

    func disposeIfCurrent(_ entry: MessagesControllerEntry) async throws {
        guard current?.value === entry.value else {
            return
        }
        try await disposeCachedController()
    }
}

extension PlatformAPI {
    // PlatformAPI wrappers share the process-wide controller and automation lane.
    private static let messagesControllerAutomationLane = MessagesControllerAutomationLane(idleDelay: 1)
    private static let messagesControllerIdleCallbackOwner = Protected<ObjectIdentifier?>()
    private static let messagesControllerCoordinator = MessagesControllerCoordinator<MessagesController>(
        create: { reportErrorMessage in
            let controller = try await runOnMessagesControllerLane {
                try await MessagesController(reportErrorMessage: { txt in
                    platformMessagesControllerLog.error("<!> report to sentry: \(txt)")
                    try? reportErrorMessage?(txt)
                })
            }
            let entry = MessagesControllerEntry(controller)
            await installMessagesControllerIdleCallback(for: entry)
            return entry
        },
        isValid: { $0.isValid },
        dispose: { entry in
            Log.default.notice("[PlatformAPI] disposing MessagesController")
            try await runOnMessagesControllerLane {
                await clearMessagesControllerIdleCallback(ifOwnedBy: entry)
                entry.value.dispose()
            }
        }
    )
    private static let messageSendGate = MessageSendGate()

    func withMessageSendLock<T>(_ operation: () async throws -> T) async throws -> T {
        try await Self.messageSendGate.run(operation)
    }

    func withMessagesController<T>(
        forceInvalidate: Bool = false,
        _ action: @escaping @Sendable (MessagesController) async throws -> T
    ) async throws -> T {
        try await Self.messagesControllerCoordinator.withController(
            reportErrorMessage: errorMessageReporter,
            hasBeenDisposed: hasBeenDisposed,
            forceInvalidate: forceInvalidate,
            action
        )
    }

    func disposeCachedMessagesController() async throws {
        try await Self.messagesControllerCoordinator.disposeCachedController()
    }

    static func runOnMessagesControllerLane<T>(
        _ action: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await messagesControllerAutomationLane.run(action)
    }

    static func setMessagesControllerIdleCallback(
        _ callback: (@Sendable () async -> Void)?
    ) async {
        await messagesControllerAutomationLane.setIdleCallback(callback)
    }

    private static func installMessagesControllerIdleCallback(for entry: MessagesControllerEntry) async {
        let owner = ObjectIdentifier(entry.value)
        messagesControllerIdleCallbackOwner.withLock { $0 = owner }
        await setMessagesControllerIdleCallback { [entry] in
            guard messagesControllerIdleCallbackOwner.read() == owner else { return }
            await PlatformAPI.observeSelectedThreadActivity(using: entry.value)
        }
    }

    private static func clearMessagesControllerIdleCallback(ifOwnedBy entry: MessagesControllerEntry) async {
        let owner = ObjectIdentifier(entry.value)
        let shouldClear = messagesControllerIdleCallbackOwner.withLock { currentOwner in
            guard currentOwner == owner else { return false }
            currentOwner = nil
            return true
        }
        guard shouldClear else { return }
        await setMessagesControllerIdleCallback(nil)
    }
}
