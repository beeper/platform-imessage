import Foundation
import IMessageCore

extension Task where Success == Never, Failure == Never {
    struct TimeoutError: Error, Equatable, Sendable {}
}

extension Task where Failure == any Error {
    static func withTimeout(
        _ timeout: TimeInterval,
        onLateSuccess: @escaping @Sendable (Success) -> Void = { _ in },
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) async throws -> Success {
        try await Task<Never, Never>._withTimeout(timeout, onLateSuccess: onLateSuccess, operation: operation)
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
        onLateSuccess: @escaping @Sendable (Output) -> Void,
        operation: sending @escaping @isolated(any) () async throws -> Output
    ) async throws -> Output {
        try Task<Never, Never>.checkCancellation()

        guard timeout > 0 else {
            throw Task<Never, Never>.TimeoutError()
        }

        let state = Protected(TimeoutState<Output>())

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let operationTask = Task<Void, Never> {
                    do {
                        try Task<Never, Never>.checkCancellation()
                        let output = try await operation()
                        if !finishTimeout(.success(output), state: state) {
                            onLateSuccess(output)
                        }
                    } catch {
                        finishTimeout(.failure(error), state: state)
                    }
                }

                let timeoutTask = Task<Void, Never> {
                    do {
                        try await sleepForTimeout(timeout)
                        try Task<Never, Never>.checkCancellation()
                        finishTimeout(.failure(Task<Never, Never>.TimeoutError()), state: state)
                    } catch {
                        finishTimeout(.failure(error), state: state)
                    }
                }

                let result = state.withLock { state -> Result<Output, Error>? in
                    if let result = state.result {
                        return result
                    }

                    state.continuation = continuation
                    state.operationTask = operationTask
                    state.timeoutTask = timeoutTask

                    return nil
                }

                if let result {
                    operationTask.cancel()
                    timeoutTask.cancel()
                    continuation.resume(with: result)
                }

                if Task<Never, Never>.isCancelled {
                    finishTimeout(.failure(Swift.CancellationError()), state: state)
                }
            }
        } onCancel: {
            finishTimeout(.failure(Swift.CancellationError()), state: state)
        }
    }

    @discardableResult
    static func finishTimeout<Output>(
        _ result: Result<Output, Error>,
        state: Protected<TimeoutState<Output>>
    ) -> Bool {
        let completion = state.withLock { state -> (
            continuation: CheckedContinuation<Output, Error>?,
            operationTask: Task<Void, Never>?,
            timeoutTask: Task<Void, Never>?
        )? in
            guard state.result == nil else {
                return nil
            }

            state.result = result

            defer {
                state.continuation = nil
                state.operationTask = nil
                state.timeoutTask = nil
            }
            return (state.continuation, state.operationTask, state.timeoutTask)
        }

        guard let completion else { return false }
        completion.operationTask?.cancel()
        completion.timeoutTask?.cancel()
        completion.continuation?.resume(with: result)
        return true
    }

    static func sleepForTimeout(_ timeout: TimeInterval) async throws {
        if #available(macOS 13.0, *) {
            try await Task<Never, Never>.sleep(for: .seconds(timeout), clock: .continuous)
        } else {
            try await Task<Never, Never>.sleep(forTimeInterval: timeout)
        }
    }
}
