import Foundation

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
    onError: ((_ attempt: Int, _ err: Error?) throws -> Void)? = nil
) throws -> T {
    let start = Date()
    var res: Result<T, Error>
    var attempt = 0
    repeat {
        res = Result(catching: perform)
        switch res {
        case let .success(val):
            return val
        case let .failure(err):
            do {
                try onError?(attempt, err)
                attempt += 1
            } catch {
                Log.errors.error("retry onError errored \(error)")
            }
        }
        interval.map(Thread.sleep(forTimeInterval:))
    } while -start.timeIntervalSinceNow < timeout
    return try res.get()
}

public func retry<T>(
    withTimeout timeout: TimeInterval,
    interval: TimeInterval? = nil,
    _ perform: () async throws -> T,
    onError: ((_ attempt: Int, _ err: Error?) async throws -> Void)? = nil
) async throws -> T {
    let start = Date()
    var res: Result<T, Error>!
    var attempt = 0
    repeat {
        await Task.yield()
        try Task.checkCancellation()
        do {
            return try await perform()
        } catch let error as CancellationError {
            throw error
        } catch {
            res = .failure(error)
            do {
                try await onError?(attempt, error)
                attempt += 1
            } catch let error as CancellationError {
                throw error
            } catch {
                Log.errors.error("retry onError errored \(error)")
            }
        }
        if let interval {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    } while -start.timeIntervalSinceNow < timeout
    return try res.get()
}

public func retry<T>(
    retries: Int,
    interval: TimeInterval? = nil,
    _ perform: (_ attempt: Int) async throws -> T,
    onError: ((_ attempt: Int, _ retriesLeft: Int, _ err: Error) async -> Void)? = nil
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await perform(attempt)
        } catch {
            let retriesLeft = max(retries - attempt, 0)
            await onError?(attempt, retriesLeft, error)
            guard attempt < retries else {
                throw error
            }
            attempt += 1
            if let interval {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
}
