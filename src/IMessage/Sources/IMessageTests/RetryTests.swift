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
