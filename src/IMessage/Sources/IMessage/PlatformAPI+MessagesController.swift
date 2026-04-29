import IMessageCore
import Logging

private let platformMessagesControllerLog = Logger(imessageLabel: "platform-api")

private struct MessagesControllerEntry: @unchecked Sendable {
    var controller: MessagesController
    var cleanupHook: PlatformAPI.CleanupHook?
}

private enum MessagesControllerCoordinatorError: Error {
    case cachedControllerInvalid
    case pendingControllerInvalidated
}

private actor MessagesControllerCoordinator {
    private var current: MessagesControllerEntry?
    // Actors are reentrant across awaits, so concurrent callers share one in-flight construction.
    private var pendingController: Task<MessagesControllerEntry, Error>?

    func withController<T>(
        runtime: PlatformAPI.Runtime,
        hasBeenDisposed: Protected<Bool>,
        forceInvalidate: Bool = false,
        _ action: @escaping @Sendable (MessagesController) throws -> T
    ) async throws -> T {
        if forceInvalidate {
            try await disposeCachedController()
        }

        while true {
            let entry = try await currentControllerEntry(runtime: runtime, hasBeenDisposed: hasBeenDisposed)

            do {
                return try await PlatformAPI.onMessagesControllerQueue {
                    guard !hasBeenDisposed.read() else {
                        throw ErrorMessage("PlatformAPI has been disposed")
                    }
                    guard entry.controller.isValid else {
                        throw MessagesControllerCoordinatorError.cachedControllerInvalid
                    }
                    return try action(entry.controller)
                }
            } catch MessagesControllerCoordinatorError.cachedControllerInvalid {
                platformMessagesControllerLog.debug("disposing cached MessagesController because it became invalid")
                try await disposeIfCurrent(entry)
            } catch MessagesControllerCoordinatorError.pendingControllerInvalidated {
                continue
            }
        }
    }

    func disposeCachedController() async throws {
        let entry = current
        let pendingController = pendingController
        current = nil
        self.pendingController = nil

        var pendingError: Error?
        if let pendingController {
            do {
                let created = try await pendingController.value
                try await dispose(created, removeCleanupHook: true)
            } catch {
                pendingError = error
            }
        }

        if let entry {
            try await dispose(entry, removeCleanupHook: true)
        }

        if let pendingError {
            throw pendingError
        }
    }

    func disposeFromCleanupHook(_ controller: MessagesController) async {
        guard let entry = current, entry.controller === controller else {
            try? await dispose(
                MessagesControllerEntry(controller: controller, cleanupHook: nil),
                removeCleanupHook: false
            )
            return
        }

        current = nil
        try? await dispose(entry, removeCleanupHook: false)
    }
}

private extension MessagesControllerCoordinator {
    func currentControllerEntry(
        runtime: PlatformAPI.Runtime,
        hasBeenDisposed: Protected<Bool>
    ) async throws -> MessagesControllerEntry {
        guard !hasBeenDisposed.read() else {
            throw ErrorMessage("PlatformAPI has been disposed")
        }

        if let current {
            return current
        }

        let controllerTask = pendingController ?? startControllerCreation(runtime: runtime)
        return try await installPendingController(controllerTask, hasBeenDisposed: hasBeenDisposed)
    }

    private func startControllerCreation(runtime: PlatformAPI.Runtime) -> Task<MessagesControllerEntry, Error> {
        let task = Task {
            try await Self.makeControllerEntry(runtime: runtime)
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

            if let current, current.controller === entry.controller {
                return current
            }

            guard pendingController == controllerTask else {
                throw MessagesControllerCoordinatorError.pendingControllerInvalidated
            }

            pendingController = nil

            guard !hasBeenDisposed.read() else {
                try await dispose(entry, removeCleanupHook: true)
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

    static func makeControllerEntry(runtime: PlatformAPI.Runtime) async throws -> MessagesControllerEntry {
        let controller = try await PlatformAPI.makeMessagesController(runtime: runtime)
        let cleanupHook = try await runtime.addCleanupHook { completion in
            Task {
                await PlatformAPI.messagesControllerCoordinator.disposeFromCleanupHook(controller)
                completion()
            }
        }
        return MessagesControllerEntry(controller: controller, cleanupHook: cleanupHook)
    }

    func disposeIfCurrent(_ entry: MessagesControllerEntry) async throws {
        guard current?.controller === entry.controller else {
            return
        }
        current = nil
        try await dispose(entry, removeCleanupHook: true)
    }

    func dispose(_ entry: MessagesControllerEntry, removeCleanupHook: Bool) async throws {
        Log.default.notice("[PlatformAPI] disposing MessagesController")
        try await PlatformAPI.onMessagesControllerQueue {
            PlatformAPI.messagesControllerQueue.setIdleCallback(nil)
            entry.controller.dispose()
        }
        if removeCleanupHook {
            try await entry.cleanupHook?.remove()
        }
    }
}

extension PlatformAPI {
    // IMessageHost is singleton-only within a process; PlatformAPI wrappers share
    // one MessagesController and queue for Messages.app automation.
    static let messagesControllerQueue = PassivelyAwareDispatchQueue(label: "messages-controller-platform-queue", idleDelay: 1)
    fileprivate static let messagesControllerCoordinator = MessagesControllerCoordinator()

    func withMessagesController<T>(
        forceInvalidate: Bool = false,
        _ action: @escaping @Sendable (MessagesController) throws -> T
    ) async throws -> T {
        try await Self.messagesControllerCoordinator.withController(
            runtime: runtime,
            hasBeenDisposed: hasBeenDisposed,
            forceInvalidate: forceInvalidate,
            action
        )
    }

    func disposeCachedMessagesController() async throws {
        try await Self.messagesControllerCoordinator.disposeCachedController()
    }

    static func onMessagesControllerQueue<T>(
        _ action: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            messagesControllerQueue.async {
                continuation.resume(with: Result { try action() })
            }
        }
    }

    static func makeMessagesController(runtime: Runtime) async throws -> MessagesController {
        try await Self.onMessagesControllerQueue {
            try MessagesController(reportToSentry: { txt in
                platformMessagesControllerLog.error("<!> report to sentry: \(txt)")
                try? runtime.reportMessageToSentry(txt)
            })
        }
    }
}
