import AppKit
import Foundation
import IMessageCore

extension NSWorkspace {
    func open(
        _ url: URL,
        configuration: OpenConfiguration,
        timeout: TimeInterval
    ) async throws -> NSRunningApplication {
        typealias OpenContinuation = CheckedContinuation<NSRunningApplication, Error>
        let state = Protected<(continuation: OpenContinuation?, completed: Bool)>((nil, false))

        let installContinuation: @Sendable (OpenContinuation) -> Bool = { continuation in
            state.withLock { state in
                guard !state.completed else {
                    return false
                }
                state.continuation = continuation
                return true
            }
        }

        let finish: @Sendable (Result<NSRunningApplication, Error>) -> Void = { result in
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
                guard installContinuation(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let timeoutTask = Task {
                    try? await Task.sleep(forTimeInterval: timeout)
                    guard !Task.isCancelled else { return }
                    finish(.failure(ErrorMessage("Timed out opening URL via LaunchServices after \(timeout)s")))
                }

                open(url, configuration: configuration) { running, error in
                    timeoutTask.cancel()
                    if let error {
                        finish(.failure(error))
                    } else if let running {
                        finish(.success(running))
                    } else {
                        finish(.failure(ErrorMessage("LaunchServices completed without returning an app")))
                    }
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }
}
