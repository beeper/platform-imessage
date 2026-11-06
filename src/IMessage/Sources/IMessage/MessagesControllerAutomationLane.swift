import Foundation

// Serializes Messages automation and polls activity while idle.
actor MessagesControllerAutomationLane {
    typealias IdleCallback = @Sendable () async -> Void

    // Child tasks inherit this token; only re-entry from the active action deadlocks.
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

    /// Starts independent work that may enqueue on this lane, preserving other task locals.
    @discardableResult
    nonisolated static func escapingTask(
        _ operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Error> {
        Self.$executionToken.withValue(nil) {
            Task {
                try await operation()
            }
        }
    }

    func setIdleCallback(_ callback: IdleCallback?) {
        idleCallback = callback
        idleEpoch += 1
        idleTask?.cancel()
        idleTask = nil
        if pendingActiveWorkCount == 0 { scheduleIdleCallback() }
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
        assert(pendingActiveWorkCount > 0, "activeWorkCompleted without a matching activeWorkSubmitted")
        pendingActiveWorkCount -= 1
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

            guard await self.idleCallbackIfStillCurrent(expectedEpoch: expectedEpoch) != nil else {
                return
            }
            await self.scheduleIdleCallback()
        }
    }

    /// Every active-work submission, idle-task cancellation, and callback change bumps `idleEpoch`,
    /// so a matching epoch implies the lane is still idle with the same callback installed.
    private func idleCallbackIfStillCurrent(expectedEpoch: UInt) -> IdleCallback? {
        idleEpoch == expectedEpoch ? idleCallback : nil
    }
}
