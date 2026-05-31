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
    private var pendingActiveWorkCount = 0
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
        activeWorkSubmitted()
        let task = enqueue(action)
        defer { activeWorkCompleted() }

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
        guard pendingActiveWorkCount == 0, idleEpoch == expectedEpoch, idleTask?.isCancelled == false else {
            return nil
        }
        return idleCallback
    }

    private func shouldContinueIdleCallbacks(expectedEpoch: UInt) -> Bool {
        pendingActiveWorkCount == 0 && idleEpoch == expectedEpoch && idleCallback != nil
    }
}
