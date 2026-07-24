import Foundation
@testable import IMessage
@testable import IMessageCore
import Testing

// Covers the async `retry` overloads (the sync Thread.sleep overload is unchanged
// and exercised indirectly elsewhere). Focus: success, retry-until-success,
// timeout rethrows the last error, onError attempt accounting, cancellation
// rethrow, and the retries-count exhaustion path.

private struct RetryTestError: Error, Equatable { let id: Int }

@Test func retryAsyncReturnsImmediatelyOnSuccess() async throws {
    let attempts = Protected<Int>(0)
    let value = try await retry(withTimeout: 1) { () async throws -> Int in
        attempts.withLock { $0 += 1 }
        return 42
    }
    #expect(value == 42)
    #expect(attempts.read() == 1)
}

@Test func retryAsyncRetriesUntilSuccess() async throws {
    let attempts = Protected<Int>(0)
    let value = try await retry(withTimeout: 5, interval: 0.01) { () async throws -> String in
        let n = attempts.withLock { $0 += 1; return $0 }
        if n < 3 { throw RetryTestError(id: n) }
        return "ok"
    }
    #expect(value == "ok")
    #expect(attempts.read() == 3)
}

@Test func retryAsyncRethrowsLastErrorOnTimeout() async throws {
    await #expect(throws: RetryTestError.self) {
        try await retry(withTimeout: 0.1, interval: 0.02) { () async throws -> Int in
            throw RetryTestError(id: -1)
        }
    }
}

@Test func retryAsyncInvokesOnErrorWithIncrementingAttempt() async throws {
    let seenAttempts = Protected<[Int]>([])
    let attempts = Protected<Int>(0)
    let value = try await retry(withTimeout: 5, interval: 0.01, { () async throws -> Int in
        let n = attempts.withLock { $0 += 1; return $0 }
        if n < 3 { throw RetryTestError(id: n) }
        return n
    }, onError: { attempt, _ in
        seenAttempts.withLock { $0.append(attempt) }
    })
    #expect(value == 3)
    #expect(seenAttempts.read() == [0, 1])
}

@Test func retryAsyncRethrowsCancellation() async throws {
    let started = Protected<Bool>(false)
    let task = Task {
        try await retry(withTimeout: 60, interval: 0.01) { () async throws -> Int in
            started.withLock { $0 = true }
            try await Task.sleep(forTimeInterval: 1) // cancelled mid-sleep
            return 0
        }
    }

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { started.read() })
    task.cancel()

    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
}

@Test func retryAsyncRethrowsCancellationDuringOnError() async throws {
    // `perform` always throws, so the retry enters `onError`; `onError` then sleeps for
    // a full second. Cancelling the task while it is parked in `onError` must propagate
    // CancellationError promptly (the sleep throws and `retry` rethrows it) rather than
    // waiting out the whole 1s sleep.
    let onErrorEntered = Protected<Bool>(false)

    let task = Task {
        try await retry(withTimeout: 60, interval: 0.01, { () async throws -> Int in
            throw RetryTestError(id: -1)
        }, onError: { _, _ in
            onErrorEntered.withLock { $0 = true }
            try await Task.sleep(forTimeInterval: 1) // cancelled mid-sleep
        })
    }

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { onErrorEntered.read() })
    let cancelledAt = Date()
    task.cancel()

    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    // Must surface promptly after cancellation, well before the 1s onError sleep would
    // have elapsed.
    #expect(cancelledAt.timeIntervalSinceNow * -1 < 0.2)
}

@Test func retryCountRethrowsCancellationWithoutRetrying() async throws {
    let attempts = Protected<Int>(0)
    let onErrorCalls = Protected<Int>(0)
    let started = Protected<Bool>(false)

    let task = Task {
        try await retry(retries: 2) { (_: Int) async throws -> Int in
            attempts.withLock { $0 += 1 }
            started.withLock { $0 = true }
            try await Task.sleep(forTimeInterval: 1)
            return 0
        } onError: { _, _, _ in
            onErrorCalls.withLock { $0 += 1 }
        }
    }

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { started.read() })
    let cancelledAt = Date()
    task.cancel()

    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(attempts.read() == 1)
    #expect(onErrorCalls.read() == 0)
    #expect(cancelledAt.timeIntervalSinceNow * -1 < 0.2)
}

@Test func retryCountChecksCancellationBeforeNextAttempt() async throws {
    let attempts = Protected<Int>(0)
    let onErrorEntered = Protected<Bool>(false)
    let releaseOnError = Protected<Bool>(false)

    let task = Task {
        try await retry(retries: 2, { (_: Int) async throws -> Int in
            attempts.withLock { $0 += 1 }
            throw RetryTestError(id: -1)
        }, onError: { _, _, _ in
            onErrorEntered.withLock { $0 = true }
            while !releaseOnError.read() {
                await Task.yield()
            }
        })
    }

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { onErrorEntered.read() })
    task.cancel()
    releaseOnError.withLock { $0 = true }

    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(attempts.read() == 1)
}

@Test func retryCountExhaustionThrowsAfterRetries() async throws {
    let attempts = Protected<Int>(0)
    await #expect(throws: RetryTestError.self) {
        try await retry(retries: 2, interval: 0.01) { (attempt: Int) async throws -> Int in
            attempts.withLock { $0 += 1 }
            throw RetryTestError(id: attempt)
        }
    }
    // retries: 2 → 1 initial attempt + 2 retries = 3 perform calls
    #expect(attempts.read() == 3)
}

@Test func retryCountReportsRetriesLeftToOnError() async throws {
    let retriesLeftSeen = Protected<[Int]>([])
    let attempts = Protected<Int>(0)
    let value = try await retry(retries: 3, interval: 0.01, { (_: Int) async throws -> String in
        let n = attempts.withLock { $0 += 1; return $0 }
        if n < 2 { throw RetryTestError(id: n) }
        return "done"
    }, onError: { _, retriesLeft, _ in
        retriesLeftSeen.withLock { $0.append(retriesLeft) }
    })
    #expect(value == "done")
    #expect(retriesLeftSeen.read() == [3]) // one failure (attempt 0) → retriesLeft = 3 - 0
}
