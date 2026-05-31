import Foundation
import IMessageCore
import Logging

private let platformMessagesControllerLog = Logger(imessageLabel: "platform-api")

private typealias MessagesControllerEntry = UncheckedSendableBox<MessagesController>

private enum MessagesControllerCoordinatorError: Error {
    case cachedControllerInvalid
    case pendingControllerInvalidated
}

// Internal (not `private`) so `@testable import IMessage` can exercise it.
actor MessagesControllerAutomationLane {
    typealias IdleCallback = @Sendable () async -> Void

    // True while an action runs on the lane. Re-entering the lane from within an
    // action would deadlock (the nested task awaits a tail the current action is
    // blocking); task-locals propagate across hops so the precondition in `run`
    // catches it.
    //
    // WARNING: @TaskLocal values are also inherited by unstructured `Task {}`
    // children spawned during a lane action. Such a child sees `isExecutingOnLane
    // == true` even after the originating action returns, so this flag must NOT be
    // used to gate an "inline fallback" — a leaked child re-entering the lane would
    // run its action off-lane, concurrently, silently breaking serialization. The
    // only safe response to re-entrancy is to fail (see `run`).
    @TaskLocal private static var isExecutingOnLane = false

    private let idleDelay: TimeInterval
    private var tail: Task<Void, Never>?
    private var queuedActiveWorkCount = 0
    private var idleEpoch: UInt = 0
    private var idleCallback: IdleCallback?
    private var idleTask: Task<Void, Never>?

    init(idleDelay: TimeInterval) {
        self.idleDelay = idleDelay
    }

    func run<T>(_ action: @Sendable @escaping () async throws -> T) async throws -> T {
        // `precondition`, not `assert`: re-entrancy must fail loudly in release too.
        // The failure mode otherwise is a *silent* deadlock (the nested op queues
        // behind the current action while the current action awaits it) — which is
        // undiagnosable in the field. A crash with this message is strictly better.
        // See the WARNING on `isExecutingOnLane`: an "inline fallback" is NOT a safe
        // alternative because the task-local leaks into spawned `Task {}` children.
        precondition(
            !Self.isExecutingOnLane,
            "re-entrant runOnMessagesControllerLane would deadlock the serial lane: " +
            "a lane action must not call back into the lane."
        )
        activeWorkWillBegin()
        let task = enqueue(action)
        defer { activeWorkDidFinish() }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func setIdleCallback(_ callback: IdleCallback?) {
        idleCallback = callback
        idleEpoch += 1
        idleTask?.cancel()
        idleTask = nil
    }

    private func enqueue<T>(_ action: @Sendable @escaping () async throws -> T) -> Task<T, Error> {
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await Self.$isExecutingOnLane.withValue(true) {
                try await action()
            }
        }

        tail = Task {
            _ = try? await task.value
        }
        return task
    }

    private func activeWorkWillBegin() {
        idleEpoch += 1
        queuedActiveWorkCount += 1
        idleTask?.cancel()
        idleTask = nil
    }

    private func activeWorkDidFinish() {
        queuedActiveWorkCount = max(0, queuedActiveWorkCount - 1)
        guard queuedActiveWorkCount == 0 else { return }
        scheduleIdleCallback()
    }

    private func scheduleIdleCallback() {
        guard idleCallback != nil else { return }

        let expectedEpoch = idleEpoch
        let idleDelay = idleDelay
        idleTask = Task {
            do {
                try await Task.sleep(forTimeInterval: idleDelay)
            } catch {
                return
            }

            let task = self.enqueuePassiveIdleCallback(expectedEpoch: expectedEpoch)
            _ = try? await task.value
        }
    }

    private func enqueuePassiveIdleCallback(expectedEpoch: UInt) -> Task<Void, Error> {
        enqueue {
            guard let callback = await self.idleCallbackIfStillCurrent(expectedEpoch: expectedEpoch) else {
                return
            }

            await callback()

            guard await self.shouldContinueIdleCallbacks(expectedEpoch: expectedEpoch) else {
                return
            }
            await self.scheduleIdleCallback()
        }
    }

    private func idleCallbackIfStillCurrent(expectedEpoch: UInt) -> IdleCallback? {
        guard queuedActiveWorkCount == 0, idleEpoch == expectedEpoch, idleTask?.isCancelled == false else {
            return nil
        }
        return idleCallback
    }

    private func shouldContinueIdleCallbacks(expectedEpoch: UInt) -> Bool {
        queuedActiveWorkCount == 0 && idleEpoch == expectedEpoch && idleCallback != nil
    }
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

        while true {
            let entry = try await currentControllerEntry(reportErrorMessage: reportErrorMessage, hasBeenDisposed: hasBeenDisposed)

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
            let controller = try await PlatformAPI.runOnMessagesControllerLane {
                try await MessagesController(reportErrorMessage: { txt in
                    platformMessagesControllerLog.error("<!> report to sentry: \(txt)")
                    try? reportErrorMessage?(txt)
                })
            }
            return MessagesControllerEntry(controller)
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
            await PlatformAPI.setMessagesControllerIdleCallback(nil)
            entry.value.dispose()
        }
    }
}

extension PlatformAPI {
    // IMessageHost is singleton-only within a process; PlatformAPI wrappers share
    // one MessagesController and one async lane for Messages.app automation.
    private static let messagesControllerAutomationLane = MessagesControllerAutomationLane(idleDelay: 1)
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

}
