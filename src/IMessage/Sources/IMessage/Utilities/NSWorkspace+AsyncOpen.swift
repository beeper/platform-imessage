import AppKit
import Foundation
import IMessageCore

extension NSWorkspace {
    typealias RunningApplicationOpenHandler = @Sendable (NSRunningApplication?, Error?) -> Void

    func waitForRunningApplicationOpen(
        timeout: TimeInterval,
        timeoutMessage: String,
        missingApplicationMessage: String = "LaunchServices completed without returning an app",
        start: (@escaping RunningApplicationOpenHandler) -> Void
    ) async throws -> NSRunningApplication {
        typealias OpenContinuation = CheckedContinuation<NSRunningApplication, Error>
        let state = Protected<(continuation: OpenContinuation?, completed: Bool, timeoutTask: Task<Void, Never>?)>((nil, false, nil))

        // Single completion point. Whoever finishes first (LaunchServices callback,
        // the timeout, or caller cancellation) resumes the continuation and tears down
        // the timeout task; everyone else is a no-op via the `completed` flag. Cancelling
        // the timeout task here (rather than only in the success callback) means a
        // cancelled or errored open doesn't leave the timeout task sleeping with its
        // captured state retained until the deadline.
        let finish: @Sendable (Result<NSRunningApplication, Error>) -> Void = { result in
            let (continuation, timeoutTask) = state.withLock { state -> (OpenContinuation?, Task<Void, Never>?) in
                guard !state.completed else {
                    return (nil, nil)
                }
                state.completed = true
                let continuation = state.continuation
                let timeoutTask = state.timeoutTask
                state.continuation = nil
                state.timeoutTask = nil
                return (continuation, timeoutTask)
            }
            timeoutTask?.cancel()
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
                    finish(.failure(ErrorMessage(timeoutMessage)))
                }
                // Publish the handle before calling `start` so a synchronous completion
                // can still cancel the timeout task through `finish`.
                state.withLock { $0.timeoutTask = timeoutTask }

                start { running, error in
                    if let error {
                        finish(.failure(error))
                    } else if let running {
                        finish(.success(running))
                    } else {
                        finish(.failure(ErrorMessage(missingApplicationMessage)))
                    }
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
            timeoutMessage: "Timed out opening URL via LaunchServices after \(timeout)s"
        ) { completion in
            open(url, configuration: configuration, completionHandler: completion)
        }
    }
}
