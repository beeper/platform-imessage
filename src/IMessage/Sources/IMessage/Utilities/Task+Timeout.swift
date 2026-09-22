import Foundation
import IMessageCore

extension Task where Success == Never, Failure == Never {
    struct TimeoutError: Error, Equatable, Sendable {}
}

extension Task where Failure == any Error {
    static func withTimeout(
        _ timeout: TimeInterval,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) async throws -> Success {
        try await Task<Never, Never>._withTimeout(timeout, operation: operation)
    }

    public init(
        name: String? = nil,
        timeout: TimeInterval,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) {
        self.init(name: name, priority: priority) {
            try await Self.withTimeout(timeout, operation: operation)
        }
    }
}

private extension Task where Success == Never, Failure == Never {
    struct TimeoutState<Output> {
        var continuation: CheckedContinuation<Output, Error>?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var result: Result<Output, Error>?
    }

    static func _withTimeout<Output>(
        _ timeout: TimeInterval,
        operation: sending @escaping @isolated(any) () async throws -> Output
    ) async throws -> Output {
        let deadline: Date = Date().addingTimeInterval(timeout)

        guard timeout > 0 else {
            throw Task<Never, Never>.TimeoutError()
        }

        let state = Protected(TimeoutState<Output>())

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let operationTask = Task<Void, Never> {
                    do {
                        finishTimeout(
                            .success(try await operation()),
                            state: state
                        )
                    } catch {
                        finishTimeout(.failure(error), state: state)
                    }
                }

                let timeoutTask = Task<Void, Never> {
                    do {
                        try await sleepUntilTimeoutDeadline(deadline)
                        try Task<Never, Never>.checkCancellation()
                        finishTimeout(.failure(Task<Never, Never>.TimeoutError()), state: state)
                    } catch {
                        finishTimeout(.failure(error), state: state)
                    }
                }

                let completion = state.withLock { state -> (
                    continuation: CheckedContinuation<Output, Error>?,
                    result: Result<Output, Error>,
                    operationTask: Task<Void, Never>?,
                    timeoutTask: Task<Void, Never>?
                )? in
                    if let result = state.result {
                        return (
                            continuation: continuation,
                            result: result,
                            operationTask: operationTask,
                            timeoutTask: timeoutTask
                        )
                    }

                    state.continuation = continuation
                    state.operationTask = operationTask
                    state.timeoutTask = timeoutTask

                    return nil
                }

                if let completion {
                    completeTimeout(
                        continuation: completion.continuation,
                        result: completion.result,
                        operationTask: completion.operationTask,
                        timeoutTask: completion.timeoutTask
                    )
                }

                if Task<Never, Never>.isCancelled {
                    finishTimeout(.failure(Swift.CancellationError()), state: state)
                }
            }
        } onCancel: {
            finishTimeout(.failure(Swift.CancellationError()), state: state)
        }
    }

    static func finishTimeout<Output>(
        _ result: Result<Output, Error>,
        state: Protected<TimeoutState<Output>>
    ) {
        let completion = state.withLock { state -> (
            continuation: CheckedContinuation<Output, Error>?,
            result: Result<Output, Error>,
            operationTask: Task<Void, Never>?,
            timeoutTask: Task<Void, Never>?
        )? in
            guard state.result == nil else {
                return nil
            }

            state.result = result

            let completion = (
                continuation: state.continuation,
                result: result,
                operationTask: state.operationTask,
                timeoutTask: state.timeoutTask
            )

            state.continuation = nil
            state.operationTask = nil
            state.timeoutTask = nil

            return completion
        }

        if let completion {
            completeTimeout(
                continuation: completion.continuation,
                result: completion.result,
                operationTask: completion.operationTask,
                timeoutTask: completion.timeoutTask
            )
        }
    }

    static func completeTimeout<Output>(
        continuation: CheckedContinuation<Output, Error>?,
        result: Result<Output, Error>,
        operationTask: Task<Void, Never>?,
        timeoutTask: Task<Void, Never>?
    ) {
        operationTask?.cancel()
        timeoutTask?.cancel()

        switch (continuation, result) {
        case let (.some(continuation), .success(value)):
            continuation.resume(returning: value)
        case let (.some(continuation), .failure(error)):
            continuation.resume(throwing: error)
        case (.none, _):
            break
        }
    }

    static func sleepUntilTimeoutDeadline(_ deadline: Date) async throws {
        let remainingTime = deadline.timeIntervalSinceNow

        guard remainingTime > 0 else {
            return
        }

        if #available(macOS 13.0, *) {
            let clock = ContinuousClock()
            let deadlineInstant = clock.now.advanced(by: .seconds(remainingTime))

            try await Task<Never, Never>.sleep(until: deadlineInstant, tolerance: nil, clock: clock)
        } else {
            try await Task<Never, Never>.sleep(forTimeInterval: remainingTime)
        }
    }
}
