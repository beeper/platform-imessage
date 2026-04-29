import IMessageCore
import Logging

private let platformMessagesControllerLog = Logger(imessageLabel: "platform-api")

extension PlatformAPI {
    // IMessageHost is singleton-only within a process; PlatformAPI wrappers share
    // one MessagesController and queue for Messages.app automation.
    static let messagesControllerQueue = PassivelyAwareDispatchQueue(label: "messages-controller-platform-queue", idleDelay: 1)
    private static var messagesController: MessagesController?
    private static var messagesControllerCleanupHook: CleanupHook?

    func getMessagesController(forceInvalidate: Bool = false) async throws -> MessagesController {
        guard !hasBeenDisposed.read() else {
            throw ErrorMessage("PlatformAPI has been disposed")
        }

        if let existing = Self.messagesController {
            let isValid = try await Self.onMessagesControllerQueue {
                existing.isValid
            }
            if isValid && !forceInvalidate {
                return existing
            }

            platformMessagesControllerLog.debug("disposing cached MessagesController (valid? \(isValid), invalidation forced? \(forceInvalidate))")
            try await disposeCachedMessagesController()
        }

        let controller = try await makeMessagesController()
        let cleanupHook = try await runtime.addCleanupHook { completion in
            Log.default.notice("[PlatformAPI] running MessagesController dispose inside cleanup hook")
            controller.dispose()
            completion()
        }

        guard !hasBeenDisposed.read() else {
            try await disposeMessagesController(controller, cleanupHook: cleanupHook)
            throw ErrorMessage("PlatformAPI has been disposed")
        }

        Self.messagesController = controller
        Self.messagesControllerCleanupHook = cleanupHook
        return controller
    }

    func disposeCachedMessagesController() async throws {
        guard let controller = Self.messagesController else {
            return
        }

        let cleanupHook = Self.messagesControllerCleanupHook
        Self.messagesController = nil
        Self.messagesControllerCleanupHook = nil
        try await disposeMessagesController(controller, cleanupHook: cleanupHook)
    }

    /// Disposes a controller. Clears the queue's idle callback and runs
    /// `controller.dispose()` inside the same `queue.sync` critical section
    /// so a pending idle callback can't fire against a half-disposed controller.
    func disposeMessagesController(_ controller: MessagesController, cleanupHook: CleanupHook?) async throws {
        Log.default.notice("[PlatformAPI] disposing MessagesController")
        Self.messagesControllerQueue.queue.sync {
            Self.messagesControllerQueue.setIdleCallback(nil)
            controller.dispose()
        }
        try await cleanupHook?.remove()
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

    func makeMessagesController() async throws -> MessagesController {
        try await Self.onMessagesControllerQueue {
            try MessagesController(reportToSentry: { [runtime = self.runtime] txt in
                platformMessagesControllerLog.error("<!> report to sentry: \(txt)")
                try? runtime.reportMessageToSentry(txt)
            })
        }
    }
}
