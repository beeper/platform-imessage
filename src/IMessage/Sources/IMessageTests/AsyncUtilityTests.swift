import Foundation
@testable import IMessage
@testable import IMessageCore
import Testing

private struct TaskTimeoutTestError: Error, Equatable {}

private final class ObservableFlag: NSObject {
    @objc dynamic var isReady = false
}

private actor TimeoutOperationGate {
    private var continuation: CheckedContinuation<Int, Never>?
    private var released = false

    func wait() async -> Int {
        if released { return 123 }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume(returning: 123)
        continuation = nil
    }
}

@Test func withTimeoutReturnsOperationValue() async throws {
    let value = try await Task.withTimeout(5) {
        42
    }

    #expect(value == 42)
}

@Test func withTimeoutPropagatesOperationError() async throws {
    await #expect(throws: TaskTimeoutTestError.self) {
        _ = try await Task.withTimeout(5) {
            throw TaskTimeoutTestError()
        }
    }
}

@Test func withTimeoutThrowsWhenOperationDoesNotFinishBeforeDeadline() async throws {
    let started = Protected(false)

    await #expect(throws: Task<Never, Never>.TimeoutError.self) {
        _ = try await Task.withTimeout(0.05) {
            started.withLock { $0 = true }
            try await Task.sleep(forTimeInterval: 60)
            return 0
        }
    }

    #expect(started.read())
}

@Test func withTimeoutAbandonsCancellationIgnoringOperation() async throws {
    // Hold the operation open until the caller has actually observed the timeout.
    // This proves abandonment without depending on a sub-200ms scheduling budget.
    let gate = TimeoutOperationGate()
    let timedOut = Protected(false)
    let task = Task {
        defer { timedOut.withLock { $0 = true } }
        return try await Task.withTimeout(0.05) { await gate.wait() }
    }
    let returnedBeforeOperation = await eventually(timeout: 2) { timedOut.read() }
    await gate.release()
    #expect(returnedBeforeOperation)
    let result = await task.result
    #expect(throws: Task<Never, Never>.TimeoutError.self) { try result.get() }
}

@Test func withTimeoutDoesNotStartAnAlreadyCancelledOperation() async {
    let started = Protected(false)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await Task.withTimeout(5) {
            started.withLock { $0 = true }
            return 42
        }
    }
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(!started.read())
}

@Test func withTimeoutPropagatesCallerCancellation() async throws {
    let started = Protected(false)
    let task = Task {
        try await Task.withTimeout(10) {
            started.withLock { $0 = true }
            try await Task.sleep(forTimeInterval: 60)
            return 0
        }
    }

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { started.read() })
    task.cancel()

    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
}

@Test func waitForExpectedValueHonorsObservationOptions() async {
    let object = ObservableFlag()
    object.isReady = true
    await #expect(throws: Task<Never, Never>.TimeoutError.self) {
        try await Task.withTimeout(0.05) {
            try await object.waitForValue(\.isReady, true, options: [.new])
        }
    }
}

@Test func waitForValuePropagatesCallerCancellation() async {
    let object = ObservableFlag()
    let observedInitialValue = Protected(false)
    let task = Task {
        try await object.waitForValue(\.isReady) { value in
            observedInitialValue.withLock { $0 = true }
            return value
        }
    }

    #expect(await eventually(timeout: 2, pollInterval: 0.005) {
        observedInitialValue.read()
    })

    task.cancel()

    let result = await task.result
    #expect(throws: CancellationError.self) {
        try result.get()
    }
}

@Test(arguments: [false, true])
func withTimeoutCleansUpLateResultsAfterTimeoutOrCancellation(cancelCaller: Bool) async {
    let gate = TimeoutOperationGate()
    let started = Protected(false)
    let cleanedUp = Protected<[Int]>([])
    let task = Task {
        try await Task.withTimeout(cancelCaller ? 10 : 0.05, onLateSuccess: { value in
            cleanedUp.withLock { $0.append(value) }
        }) {
            started.withLock { $0 = true }
            return await gate.wait()
        }
    }
    #expect(await eventually { started.read() })
    if cancelCaller { task.cancel() }
    let result = await task.result
    if cancelCaller {
        #expect(throws: CancellationError.self) { try result.get() }
    } else {
        #expect(throws: Task<Never, Never>.TimeoutError.self) { try result.get() }
    }
    #expect(cleanedUp.read().isEmpty)
    await gate.release()
    #expect(await eventually { cleanedUp.read() == [123] })
}

@Test @MainActor func asyncSmokeWorkerAllowsMainActorHops() async throws {
    let value = try await runSmokeWorker {
        await MainActor.run { 42 }
    }
    #expect(value == 42)
}
