import Dispatch
import Foundation
import Logging

private let log = Logger(swiftServerLabel: "idle-aware-queue")

public enum Quiescence {
    /// Passive work was scheduled due to a lull in active work.
    case began
    /// No active work has been scheduled since the idle callback was last scheduled.
    case continuing
}

public final class PassivelyAwareDispatchQueue {
    public typealias PassiveCallback = @Sendable (Quiescence) -> Void

    public let queue: DispatchQueue

    private var pending = Protected<Int>(0)
    private var passiveWorkItem: DispatchWorkItem?
    private var uponIdle = Protected<PassiveCallback?>()
    private var activityEpoch = Protected<UInt>(0)
    public private(set) var idleDelay: TimeInterval

    public init(label: String, idleDelay: TimeInterval, qos: DispatchQoS = .unspecified) {
        self.queue = DispatchQueue(label: label, qos: qos)
        self.idleDelay = idleDelay
    }

    // Updating the idle callback is not itself considered "work" at all; it
    // happens instantly and it'll run even if the passive work item was
    // scheduled before the callback was updated.
    public func setIdleCallback(_ callback: PassiveCallback?) {
        uponIdle.withLock { $0 = callback }
    }

    public func async(execute activeWork: @Sendable @escaping () -> Void) {
        let (epoch, newCount) = bumpStateInResponseToWorkSubmission()

        queue.async { [self] in
            activeWork()

            let pendingPostDecrement = pending.withLock {
                $0 -= 1
                return $0
            }
#if DEBUG
            log.debug("\(queue.label): ✅ finished work, pending is now \(pendingPostDecrement)")
#endif
            if pendingPostDecrement == 0 {
                // There isn't any work left in the queue, so arm the passive
                // work to potentially execute soon.
                armPassive(expectingEpoch: epoch, quiescence: .began)
            }
        }
    }
}

private extension PassivelyAwareDispatchQueue {
    private func bumpStateInResponseToWorkSubmission() -> (epoch: UInt, newCount: Int) {
        let newEpoch = activityEpoch.withLock { $0 += 1; return $0 }
        // If we had scheduled passive work, prevent it from running. This won't
        // stop it if it already had a chance to begin executing, though.
        passiveWorkItem?.cancel()
        passiveWorkItem = nil
        let newCount = pending.withLock { $0 += 1; return $0 }
#if DEBUG
        log.debug("\(queue.label): 🔄 enqueuing work, pending is now \(newCount)")
#endif
        return (newEpoch, newCount)
    }

    // This is only ever called from the queue, so we don't need to protect `passiveWorkItem`.
    func armPassive(expectingEpoch expectedEpoch: UInt, quiescence: Quiescence) {
        passiveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
#if DEBUG
            // log.debug("\(queue.label): 💭 running passive work now")
#endif

            let isQuiet = pending.read() == 0
            let epochUnchanged = activityEpoch.read() == expectedEpoch
            guard isQuiet, epochUnchanged else {
#if DEBUG
                log.debug("\(queue.label): 🚫 backing out of passive work (quiet? \(isQuiet), epoch unchanged? \(epochUnchanged))")
#endif
                return
            }

            uponIdle.read()?(quiescence)

            if pending.read() == 0 {
                // If no active work was scheduled while we were busy with
                // passive work, schedule the passive work to run again soon.
                armPassive(expectingEpoch: expectedEpoch, quiescence: .continuing)
            }
        }

        // Prime passive work, scheduling it to run at some point in the future.
        //
        // It is immediately cancelled when active work is submitted; in other
        // words, the mere submission of active work preempts the execution of
        // passive work.
        queue.asyncAfter(deadline: .now() + idleDelay, execute: workItem)
        passiveWorkItem = workItem
    }
}
