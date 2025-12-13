import Foundation
import Dispatch

// TODO: (@pmanot) - rename


private final class DispatchQueueSerialExecutor: SerialExecutor {
    let queue: DispatchQueue
    
    init(queue: DispatchQueue) {
        self.queue = queue
    }
    
    func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }
    
    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

@globalActor
public actor UnsafeSynchronousBridgeActor {
    // Configure the queue used by this global actor.
    // IMPORTANT: Do not call `unsafeBlockCurrentThreadUntilComplete` from this queue.
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "unsafe.synchronous.bridge.actor")
        q.setSpecific(key: queueKey, value: 1)
        return q
    }()
    
    private static let executor = DispatchQueueSerialExecutor(queue: queue)
    
    public static let shared = UnsafeSynchronousBridgeActor(
        executor: executor.asUnownedSerialExecutor()
    )
    
    private nonisolated let executorRef: UnownedSerialExecutor
    
    private init(executor: UnownedSerialExecutor) {
        self.executorRef = executor
    }
    
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorRef
    }
    
    /// Returns true if the current code is executing on the actor's backing queue.
    public static func isOnActorQueue() -> Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }
}

/// DANGEROUS: Blocks the current thread until the async operation completes.
/// - Important:
///   - Do NOT call on the main thread.
///   - Do NOT call from `UnsafeSynchronousBridgeActor`'s backing queue (will deadlock).
///   - The async operation must not require progress on the blocked thread/queue to complete.
@discardableResult
public func unsafeBlockCurrentThreadUntilComplete<T>(
    _ operation: @escaping @Sendable () async throws -> T
) throws -> T {
    precondition(!Thread.isMainThread, "unsafeBlockCurrentThreadUntilComplete must not be called on the main thread.")
    precondition(!UnsafeSynchronousBridgeActor.isOnActorQueue(),
                 "unsafeBlockCurrentThreadUntilComplete called from UnsafeSynchronousBridgeActor queue; this will deadlock.")
    
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    
    Task.detached { @UnsafeSynchronousBridgeActor in
        defer { semaphore.signal() }
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
    }
    
    semaphore.wait()
    return try result.get()
}
