import Dispatch
import Foundation
import Logging

private let log = Logger(imessageLabel: "idle-aware-queue")

public enum Quiescence {
    /// Passive work was scheduled due to a lull in active work.
    case began
    /// No active work has been scheduled since the idle callback was last scheduled.
    case continuing
}

public final class PassivelyAwareDispatchQueue {
    public typealias PassiveCallback = @Sendable (Quiescence) -> Void

    public let queue: DispatchQueue

    private var activityState = Protected(ActivityState())
    private var uponIdle = Protected<PassiveCallback?>()
    public private(set) var idleDelay: TimeInterval

    public init(label: String, idleDelay: TimeInterval, qos: DispatchQoS = .unspecified) {
        self.queue = DispatchQueue(label: label, qos: qos)
        self.idleDelay = idleDelay
    }

    // Updating the idle callback is not itself considered "work" at all; it
    // happens instantly and it'll run even if the passive work was
    // scheduled before the callback was updated.
    public func setIdleCallback(_ callback: PassiveCallback?) {
        uponIdle.withLock { $0 = callback }
    }

    public func async(execute activeWork: @Sendable @escaping () -> Void) {
        bumpStateInResponseToWorkSubmission()

        queue.async { [self] in
            activeWork()

            let (pendingPostDecrement, currentEpoch) = completeWork()
            #if DEBUG
            log.debug("\(queue.label): ✅ finished work, pending is now \(pendingPostDecrement)")
            #endif
            if pendingPostDecrement == 0 {
                // There isn't any work left in the queue, so arm the passive
                // work to potentially execute soon.
                armPassive(expectingEpoch: currentEpoch, quiescence: .began)
            }
        }
    }
}

private extension PassivelyAwareDispatchQueue {
    struct ActivityState {
        var pending = 0
        var epoch: UInt = 0
    }

    private func bumpStateInResponseToWorkSubmission() {
        let newCount = activityState.withLock { state in
            state.epoch += 1
            state.pending += 1
            return state.pending
        }
        #if DEBUG
        log.debug("\(queue.label): 🔄 enqueuing work, pending is now \(newCount)")
        #endif
    }

    private func completeWork() -> (pending: Int, epoch: UInt) {
        activityState.withLock { state in
            state.pending -= 1
            return (state.pending, state.epoch)
        }
    }

    func armPassive(expectingEpoch expectedEpoch: UInt, quiescence: Quiescence) {
        // Submission-side epoch changes logically cancel delayed idle checks
        // without retaining and releasing DispatchWorkItems across threads.
        queue.asyncAfter(deadline: .now() + idleDelay) { [weak self] in
            guard let self else { return }
            #if DEBUG
            // log.debug("\(queue.label): 💭 running passive work now")
            #endif

            let (isQuiet, epochUnchanged) = activityState.withLock { state in
                (state.pending == 0, state.epoch == expectedEpoch)
            }
            guard isQuiet, epochUnchanged else {
                #if DEBUG
                log.debug("\(queue.label): 🚫 backing out of passive work (quiet? \(isQuiet), epoch unchanged? \(epochUnchanged))")
                #endif
                return
            }

            uponIdle.read()?(quiescence)

            let shouldContinue = activityState.withLock { state in
                state.pending == 0 && state.epoch == expectedEpoch
            }
            if shouldContinue {
                // If no active work was scheduled while we were busy with
                // passive work, schedule the passive work to run again soon.
                armPassive(expectingEpoch: expectedEpoch, quiescence: .continuing)
            }
        }
    }
}
