import IMessageCore
import Logging

private let platformMessagesControllerLog = Logger(imessageLabel: "platform-api")

private struct MessagesControllerEntry: @unchecked Sendable {
    var controller: MessagesController
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
        reportErrorMessage: PlatformAPI.ReportErrorMessage?,
        hasBeenDisposed: Protected<Bool>,
        forceInvalidate: Bool = false,
        _ action: @escaping @Sendable (MessagesController) throws -> T
    ) async throws -> T {
        if forceInvalidate {
            try await disposeCachedController()
        }

        while true {
            let entry = try await currentControllerEntry(reportErrorMessage: reportErrorMessage, hasBeenDisposed: hasBeenDisposed)

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
                try await dispose(created)
            } catch {
                pendingError = error
            }
        }

        if let entry {
            try await dispose(entry)
        }

        if let pendingError {
            throw pendingError
        }
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
            try await Self.makeControllerEntry(reportErrorMessage: reportErrorMessage)
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

    static func makeControllerEntry(reportErrorMessage: PlatformAPI.ReportErrorMessage?) async throws -> MessagesControllerEntry {
        let controller = try await PlatformAPI.makeMessagesController(reportErrorMessage: reportErrorMessage)
        return MessagesControllerEntry(controller: controller)
    }

    func disposeIfCurrent(_ entry: MessagesControllerEntry) async throws {
        guard current?.controller === entry.controller else {
            return
        }
        current = nil
        try await dispose(entry)
    }

    func dispose(_ entry: MessagesControllerEntry) async throws {
        Log.default.notice("[PlatformAPI] disposing MessagesController")
        try await PlatformAPI.onMessagesControllerQueue {
            PlatformAPI.messagesControllerQueue.setIdleCallback(nil)
            entry.controller.dispose()
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
            reportErrorMessage: errorMessageReporter,
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

    static func makeMessagesController(reportErrorMessage: ReportErrorMessage?) async throws -> MessagesController {
        try await Self.onMessagesControllerQueue {
            try MessagesController(reportToSentry: { txt in
                platformMessagesControllerLog.error("<!> report to sentry: \(txt)")
                try? reportErrorMessage?(txt)
            })
        }
    }
}
