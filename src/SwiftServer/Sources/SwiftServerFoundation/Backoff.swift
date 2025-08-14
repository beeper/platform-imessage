import Foundation

public struct Backoff {
    var baseDelay: TimeInterval
    var resetWhenSucceededFor: TimeInterval? = 5.0

    var fails = 0
    var lastFailure: Date?

    public init(baseDelay: TimeInterval = 0.2) {
        precondition(baseDelay > 0)
        self.baseDelay = baseDelay
    }

    var retryAfter: TimeInterval {
        return baseDelay * pow(2.0, Double(fails))
    }

    mutating func reset() {
        fails = 0
    }

    mutating func fail() -> (failuresSoFar: Int, wait: TimeInterval) {
        defer { lastFailure = Date() }

        // After having waited due to a failure, if we don't fail within the
        // following time period as determined by `resetWhenSucceededFor`,
        // restart at 1 fail.
        if let lastFailure, let resetWhenSucceededFor, Date().timeIntervalSince(lastFailure) > retryAfter + resetWhenSucceededFor {
            reset()
        }

        fails += 1
        return (fails, retryAfter)
    }
}
