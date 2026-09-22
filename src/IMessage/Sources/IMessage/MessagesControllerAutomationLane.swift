import Foundation

// A single serial async "lane" for Messages.app automation, plus passive idle
// detection. All MessagesController automation funnels through one shared instance
// (see `PlatformAPI.runOnMessagesControllerLane`) so only one operation touches
// Messages.app at a time — this replaced the old DispatchQueue + UnfairLock model.
//
// `run` enqueues an action behind a tail of previously-submitted work; when the
// queue drains, an idle callback fires after `idleDelay` and keeps firing while the
// lane stays quiet (epoch-guarded so new active work cancels a stale idle cycle).
actor MessagesControllerAutomationLane {
    typealias IdleCallback = @Sendable () async -> Void

    // Identifies the lane action from which the current task descends. Children
    // inherit the token, so `run` compares it with the action currently holding the
    // lane: an expired token is safe, while a matching token would deadlock.
    @TaskLocal private static var executionToken: UUID?

    private let idleDelay: TimeInterval
    private var tail: Task<Void, Never>?
    private var activeExecutionToken: UUID?
    private var pendingActiveWorkCount = 0
    private var idleEpoch: UInt = 0
    private var idleCallback: IdleCallback?
    private var idleTask: Task<Void, Never>?

    init(idleDelay: TimeInterval) {
        self.idleDelay = idleDelay
    }

    func run<T>(_ action: @Sendable @escaping () async throws -> T) async throws -> T {
        if let executionToken = Self.executionToken {
            // `precondition`, not `assert`: re-entering from the action currently
            // holding the lane would silently deadlock in release.
            precondition(
                executionToken != activeExecutionToken,
                "re-entrant runOnMessagesControllerLane would deadlock the serial lane: " +
                "a lane action must not call back into the lane."
            )
        }
        activeWorkSubmitted()
        let task = enqueue(action)
        defer { activeWorkCompleted() }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Creates fire-and-forget work that must be allowed to call back into the lane
    /// independently of the action that spawned it. Only the lane token is cleared;
    /// priority and unrelated task-local values retain normal `Task {}` inheritance.
    @discardableResult
    nonisolated static func escapingTask(
        priority: TaskPriority? = nil,
        _ operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Error> {
        Self.$executionToken.withValue(nil) {
            Task(priority: priority) {
                try await operation()
            }
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
        let executionToken = UUID()
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            activeExecutionToken = executionToken
            defer { activeExecutionToken = nil }
            return try await Self.$executionToken.withValue(executionToken) {
                try await action()
            }
        }

        tail = Task {
            _ = try? await task.value
        }
        return task
    }

    private func activeWorkSubmitted() {
        idleEpoch += 1
        pendingActiveWorkCount += 1
        idleTask?.cancel()
        idleTask = nil
    }

    private func activeWorkCompleted() {
        // Every activeWorkCompleted must pair with a prior activeWorkSubmitted.
        // The assert surfaces an imbalance in debug; the max(0,…) keeps release safe.
        assert(pendingActiveWorkCount > 0, "activeWorkCompleted without a matching activeWorkSubmitted")
        pendingActiveWorkCount = max(0, pendingActiveWorkCount - 1)
        guard pendingActiveWorkCount == 0 else { return }
        scheduleIdleCallback()
    }

    private func scheduleIdleCallback() {
        guard idleCallback != nil else { return }

        let expectedEpoch = idleEpoch
        let idleDelay = idleDelay
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(forTimeInterval: idleDelay)
            } catch {
                return
            }

            guard let self else { return }
            // `await` the hop back onto the actor: with `[weak self]` the closure is no
            // longer statically actor-isolated, so the actor-isolated enqueue must be awaited.
            let task = await self.enqueuePassiveIdleCallback(expectedEpoch: expectedEpoch)
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
        guard pendingActiveWorkCount == 0, idleEpoch == expectedEpoch, idleTask?.isCancelled == false else {
            return nil
        }
        return idleCallback
    }

    private func shouldContinueIdleCallbacks(expectedEpoch: UInt) -> Bool {
        pendingActiveWorkCount == 0 && idleEpoch == expectedEpoch && idleCallback != nil
    }
}
