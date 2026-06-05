import Foundation
@testable import IMessage
@testable import IMessageCore
import Testing

private struct TaskTimeoutTestError: Error, Equatable {}

private final class ObservableFlag: NSObject {
    @objc dynamic var isReady = false
}

@Test func withTimeoutReturnsOperationValue() async throws {
    let value = try await withTimeout(5) {
        42
    }

    #expect(value == 42)
}

@Test func withTimeoutPropagatesOperationError() async throws {
    await #expect(throws: TaskTimeoutTestError.self) {
        _ = try await withTimeout(5) {
            throw TaskTimeoutTestError()
        }
    }
}

@Test func withTimeoutThrowsWhenOperationDoesNotFinishBeforeDeadline() async throws {
    let started = Protected(false)
    let startedAt = Date()

    await #expect(throws: TimeoutError.self) {
        _ = try await withTimeout(0.05) {
            started.withLock { $0 = true }
            try await Task.sleep(forTimeInterval: 60)
            return 0
        }
    }

    #expect(started.read())
    #expect(Date().timeIntervalSince(startedAt) < 1)
}

@Test func withTimeoutPropagatesCallerCancellation() async throws {
    let started = Protected(false)
    let task = Task {
        try await withTimeout(10) {
            started.withLock { $0 = true }
            try await Task.sleep(forTimeInterval: 60)
            return 0
        }
    }

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { started.read() })
    let cancelledAt = Date()
    task.cancel()

    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(Date().timeIntervalSince(cancelledAt) < 1)
}

@Test func waitForValueReturnsWhenObservedValueMatches() async throws {
    let object = ObservableFlag()
    let task = Task {
        try await object.waitForValue(\.isReady, timeout: 2) { $0 }
    }

    object.isReady = true

    let value = try await task.value
    #expect(value)
}

@Test func waitForValueUsesTimeoutWhenObservedValueNeverMatches() async throws {
    let object = ObservableFlag()

    await #expect(throws: TimeoutError.self) {
        _ = try await object.waitForValue(\.isReady, timeout: 0.05) { $0 }
    }
}

@Test func openDeepLinkHonorsZeroTimeoutBeforeLaunchServicesOpen() async throws {
    await #expect(throws: TimeoutError.self) {
        _ = try await MessagesController.openDeepLink(.compose, timeout: 0)
    }
}
