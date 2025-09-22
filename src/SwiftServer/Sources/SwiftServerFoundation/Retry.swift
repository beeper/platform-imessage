import Foundation
import Sentry

/// Continuously retries a throwing function until it succeeds.
///
/// The value returned by the function is immediately returned upon success.
///
/// - Parameters:
///   - timeout:
///     The maximum amount of time that should be spent retrying. This includes
///     any time spent sleeping. This value is only consulted after each
///     cycle of calling the throwing function, invoking `onError` if
///     necessary, and sleeping; therefore, the actual elapsed real time spent
///     in this function may exceed the duration specified by this parameter.
///
///   - interval:
///     How long to sleep between failed attempts, in seconds. The sleep occurs
///     via ``Thread.sleep`` (i.e., this function blocks).
///
///   - perform: The fallible function to invoke.
///
///   - onError: Called with the current attempt (starting at zero and
///     incrementing with each failure) and `Error` upon error.
///
/// - Throws:
///   The error thrown by the throwing function, which can occur if the
///   timeout is exceeded.
///
/// - Returns: The value returned from the throwing function.
public func retry<T>(
    withTimeout timeout: TimeInterval,
    interval: TimeInterval? = nil,
    _ perform: () throws -> T,
    onError: ((_ attempt: Int, _ err: Error?) throws -> Void)? = nil,
    function: StaticString = #function,
) throws -> T {
    let start = Date()
    var res: Result<T, Error>
    var attempt = 0
    
    let span = currentlyActiveSpan?.startChild(operation: "retry", description: "\(function)")
    span?.setTag(value: "\(timeout)", key: "retry.timeout")
    span?.setTag(value: "\(interval ?? 0)", key: "retry.interval")

    repeat {
        let attemptSpan = span?.startChild(operation: "retry.attempt", description: "#\(attempt)")
        
        res = $_currentParentSpan.withValue(attemptSpan) {
            Result(catching: perform)
        }

        switch res {
        case let .success(val):
            attemptSpan?.finish()
            span?.finish()
            return val
        case let .failure(err):
            breadcrumb("\(function): retry attempt #\(attempt) failed: \(String(describing: err))", category: "retry", type: "error", level: .error)
            SentrySDK.capture(error: err)
            attemptSpan?.finish(status: .internalError)
            do {
                try onError?(attempt, err)
                attempt += 1
            } catch {
                breadcrumb("\(function): retry onError itself errored (#\(attempt)): \(String(describing: error))", category: "retry", type: "error", level: .error)
                SentrySDK.capture(error: err)
                Log.errors.error("\(function): retry onError errored \(error)")
            }
        }
        interval.map(Thread.sleep(forTimeInterval:))
    } while -start.timeIntervalSinceNow < timeout

    if case let .failure(err) = res {
        // (already captured from above)
        span?.finish(status: .internalError)
    }
    return try res.get()
}
