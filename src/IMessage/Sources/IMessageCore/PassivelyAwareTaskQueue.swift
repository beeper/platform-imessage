import Dispatch
import Foundation
import Logging

private let taskQueueLog = Logger(imessageLabel: "idle-aware-task-queue")

public final class PassivelyAwareTaskQueue: @unchecked Sendable {
    public typealias PassiveCallback = @Sendable (Quiescence) async -> Void

    public private(set) var idleDelay: TimeInterval

    private let label: String
    private let idleScheduler: DispatchQueue
    private let serialQueue = SerialTaskQueue()
    private var activityState = Protected(ActivityState())
    private var uponIdle = Protected<PassiveCallback?>()

    public init(label: String, idleDelay: TimeInterval) {
        self.label = label
        self.idleDelay = idleDelay
        self.idleScheduler = DispatchQueue(label: "\(label)-idle-scheduler")
    }

    public func setIdleCallback(_ callback: PassiveCallback?) {
        uponIdle.withLock { $0 = callback }
    }

    public func async<T>(_ activeWork: @Sendable @escaping () async throws -> T) async throws -> T {
        bumpStateInResponseToWorkSubmission()

        do {
            let result = try await serialQueue.run(activeWork)
            finishWork()
            return result
        } catch {
            finishWork()
            throw error
        }
    }
}

private extension PassivelyAwareTaskQueue {
    struct ActivityState {
        var pending = 0
        var epoch: UInt = 0
    }

    func bumpStateInResponseToWorkSubmission() {
        let newCount = activityState.withLock { state in
            state.epoch += 1
            state.pending += 1
            return state.pending
        }
        #if DEBUG
        taskQueueLog.debug("\(label): enqueuing async work, pending is now \(newCount)")
        #endif
    }

    func finishWork() {
        let (pendingPostDecrement, currentEpoch) = activityState.withLock { state in
            state.pending -= 1
            return (state.pending, state.epoch)
        }

        #if DEBUG
        taskQueueLog.debug("\(label): finished async work, pending is now \(pendingPostDecrement)")
        #endif

        if pendingPostDecrement == 0 {
            armPassive(expectingEpoch: currentEpoch, quiescence: .began)
        }
    }

    func armPassive(expectingEpoch expectedEpoch: UInt, quiescence: Quiescence) {
        idleScheduler.asyncAfter(deadline: .now() + idleDelay) { [weak self] in
            guard let self else { return }
            Task {
                await self.runPassive(expectingEpoch: expectedEpoch, quiescence: quiescence)
            }
        }
    }

    func runPassive(expectingEpoch expectedEpoch: UInt, quiescence: Quiescence) async {
        let shouldRun = activityState.withLock { state in
            state.pending == 0 && state.epoch == expectedEpoch
        }
        guard shouldRun else {
            #if DEBUG
            taskQueueLog.debug("\(label): backing out of passive async work before enqueue")
            #endif
            return
        }

        await serialQueue.run {
            let shouldStillRun = self.activityState.withLock { state in
                state.pending == 0 && state.epoch == expectedEpoch
            }
            guard shouldStillRun else {
                #if DEBUG
                taskQueueLog.debug("\(self.label): backing out of passive async work after enqueue")
                #endif
                return
            }

            await self.uponIdle.read()?(quiescence)

            let shouldContinue = self.activityState.withLock { state in
                state.pending == 0 && state.epoch == expectedEpoch
            }
            if shouldContinue {
                self.armPassive(expectingEpoch: expectedEpoch, quiescence: .continuing)
            }
        }
    }
}

private actor SerialTaskQueue {
    private var tail: Task<Void, Never>?

    func run<T>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let task = enqueue(operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func run(_ operation: @Sendable @escaping () async -> Void) async {
        let task = enqueue {
            await operation()
        }
        _ = try? await task.value
    }

    private func enqueue<T>(_ operation: @Sendable @escaping () async throws -> T) -> Task<T, Error> {
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }

        tail = Task {
            _ = try? await task.value
        }
        return task
    }
}
