import AppKit
import Foundation
import IMessageCore

extension NSWorkspace {
    typealias RunningApplicationOpenCompletion = @Sendable (Result<NSRunningApplication, Error>) -> Void

    func waitForRunningApplicationOpen(
        timeout: TimeInterval,
        timeoutError: @escaping @Sendable () -> Error,
        start: (@escaping RunningApplicationOpenCompletion) -> Void
    ) async throws -> NSRunningApplication {
        typealias OpenContinuation = CheckedContinuation<NSRunningApplication, Error>
        let state = Protected<(continuation: OpenContinuation?, completed: Bool)>((nil, false))

        let finish: RunningApplicationOpenCompletion = { result in
            let continuation = state.withLock { state -> OpenContinuation? in
                guard !state.completed else {
                    return nil
                }
                state.completed = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(with: result)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: OpenContinuation) in
                guard state.withLock({
                    guard !$0.completed else {
                        return false
                    }
                    $0.continuation = continuation
                    return true
                }) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let timeoutTask = Task {
                    try? await Task.sleep(forTimeInterval: timeout)
                    guard !Task.isCancelled else { return }
                    finish(.failure(timeoutError()))
                }

                start { result in
                    timeoutTask.cancel()
                    finish(result)
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func open(
        _ url: URL,
        configuration: OpenConfiguration,
        timeout: TimeInterval
    ) async throws -> NSRunningApplication {
        try await waitForRunningApplicationOpen(
            timeout: timeout,
            timeoutError: { ErrorMessage("Timed out opening URL via LaunchServices after \(timeout)s") }
        ) { finish in
            open(url, configuration: configuration) { running, error in
                if let error {
                    finish(.failure(error))
                } else if let running {
                    finish(.success(running))
                } else {
                    finish(.failure(ErrorMessage("LaunchServices completed without returning an app")))
                }
            }
        }
    }
}
