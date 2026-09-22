import Foundation
import IMessageCore
import Logging

private let platformMessagesControllerLog = Logger(imessageLabel: "platform-api")

private typealias MessagesControllerEntry = UncheckedSendableBox<MessagesController>

private enum MessagesControllerCoordinatorError: Error {
    case cachedControllerInvalid
    case pendingControllerInvalidated
}

private actor MessagesControllerCoordinator {
    private var current: MessagesControllerEntry?
    // Actors are reentrant across awaits, so concurrent callers share one in-flight construction.
    private var pendingController: Task<MessagesControllerEntry, Error>?

    func withController<T>(
        reportErrorMessage: PlatformAPI.ReportErrorMessage?,
        hasBeenDisposed: Protected<Bool>,
        forceInvalidate: Bool = false,
        _ action: @escaping @Sendable (MessagesController) async throws -> T
    ) async throws -> T {
        if forceInvalidate {
            try await disposeCachedController()
        }

        // Bound the loop so a controller that keeps coming up invalid can't spin forever;
        // each iteration either succeeds, throws, or retries after an invalidation.
        let maxInvalidations = 30
        var invalidations = 0
        while true {
            try Task.checkCancellation()
            let entry: MessagesControllerEntry
            do {
                entry = try await currentControllerEntry(
                    reportErrorMessage: reportErrorMessage,
                    hasBeenDisposed: hasBeenDisposed
                )
            } catch MessagesControllerCoordinatorError.pendingControllerInvalidated {
                try Task.checkCancellation()
                invalidations += 1
                guard invalidations < maxInvalidations else {
                    throw ErrorMessage("MessagesController repeatedly invalid")
                }
                continue
            }

            do {
                return try await PlatformAPI.runOnMessagesControllerLane {
                    guard !hasBeenDisposed.read() else {
                        throw ErrorMessage("PlatformAPI has been disposed")
                    }
                    guard entry.value.isValid else {
                        throw MessagesControllerCoordinatorError.cachedControllerInvalid
                    }
                    return try await action(entry.value)
                }
            } catch MessagesControllerCoordinatorError.cachedControllerInvalid {
                platformMessagesControllerLog.debug("disposing cached MessagesController because it became invalid")
                try await disposeIfCurrent(entry)
                invalidations += 1
                guard invalidations < maxInvalidations else {
                    throw ErrorMessage("MessagesController repeatedly invalid")
                }
            }
        }
    }

    func disposeCachedController() async throws {
        let entry = current
        let pendingController = pendingController
        current = nil
        self.pendingController = nil

        // Run the await-construction-then-dispose inside an unstructured Task so it is
        // immune to cancellation of *this* call. Unstructured tasks don't inherit the
        // caller's cancellation, and `await disposal.value` completes regardless of it.
        // Otherwise, if the caller is cancelled while we await `pendingController.value`,
        // this method would throw, the detached construction Task would keep running,
        // and the MessagesController it creates (having launched Messages.app) would
        // never be disposed — a leak. We deliberately do NOT cancel `pendingController`
        // itself: cancelling construction mid app-launch could leave a half-launched
        // Messages.app.
        let disposal = Task {
            var pendingError: Error?
            if let pendingController {
                do {
                    let created = try await pendingController.value
                    try await self.dispose(created)
                } catch {
                    pendingError = error
                }
            }

            if let entry {
                try await self.dispose(entry)
            }

            if let pendingError {
                throw pendingError
            }
        }
        try await disposal.value
    }
}

private extension MessagesControllerCoordinator {
    func currentControllerEntry(
        reportErrorMessage: PlatformAPI.ReportErrorMessage?,
        hasBeenDisposed: Protected<Bool>
    ) async throws -> MessagesControllerEntry {
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
            let controller = try await PlatformAPI.runOnMessagesControllerLane {
                try await MessagesController(reportErrorMessage: { txt in
                    platformMessagesControllerLog.error("<!> report to sentry: \(txt)")
                    try? reportErrorMessage?(txt)
                })
            }
            let entry = MessagesControllerEntry(controller)
            await PlatformAPI.installMessagesControllerIdleCallback(for: entry)
            return entry
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

            pendingController = nil

            guard !hasBeenDisposed.read() else {
                try await dispose(entry)
                throw ErrorMessage("PlatformAPI has been disposed")
            }

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
        current = nil
        try await dispose(entry)
    }

    func dispose(_ entry: MessagesControllerEntry) async throws {
        Log.default.notice("[PlatformAPI] disposing MessagesController")
        try await PlatformAPI.runOnMessagesControllerLane {
            await PlatformAPI.clearMessagesControllerIdleCallback(ifOwnedBy: entry)
            entry.value.dispose()
        }
    }
}

extension PlatformAPI {
    // IMessageHost is singleton-only within a process; PlatformAPI wrappers share
    // one MessagesController and one async lane for Messages.app automation.
    private static let messagesControllerAutomationLane = MessagesControllerAutomationLane(idleDelay: 1)
    private static let messagesControllerIdleCallbackOwner = Protected<ObjectIdentifier?>()
    fileprivate static let messagesControllerCoordinator = MessagesControllerCoordinator()

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

    fileprivate static func installMessagesControllerIdleCallback(for entry: MessagesControllerEntry) async {
        let owner = ObjectIdentifier(entry.value)
        messagesControllerIdleCallbackOwner.withLock { $0 = owner }
        await setMessagesControllerIdleCallback { [entry] in
            guard messagesControllerIdleCallbackOwner.read() == owner else { return }
            await PlatformAPI.observeSelectedThreadActivity(using: entry.value)
        }
    }

    fileprivate static func clearMessagesControllerIdleCallback(ifOwnedBy entry: MessagesControllerEntry) async {
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
