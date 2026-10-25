import Foundation
import IMessageCore
import Testing

// Synchronous AppKit calls run on a worker while the main run loop delivers
// lifecycle notifications. Blocking the main thread leaves cached app state stale.
@MainActor
func runSmokeWorker<Value>(_ operation: @escaping () throws -> Value) throws -> Value {
    let result = Protected<Result<Value, Error>?>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let completed = Result(catching: operation)
        result.withLock { $0 = completed }
        done.signal()
    }
    while done.wait(timeout: .now()) != .success {
        pumpSmokeRunLoop(for: 0.01)
    }
    return try #require(result.read()).get()
}

@MainActor
func pumpSmokeRunLoop(for interval: TimeInterval) {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}
