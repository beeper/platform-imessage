import Foundation

extension DispatchTimeInterval {
    var nanoseconds: UInt64 {
        func clampedNanoseconds(_ value: Double) -> UInt64 {
            guard value > 0 else { return 0 }
            guard value < Double(UInt64.max) else { return UInt64.max }
            return UInt64(value)
        }

        switch self {
        case .seconds(let seconds):
            return clampedNanoseconds(Double(seconds) * 1_000_000_000)
        case .milliseconds(let milliseconds):
            return clampedNanoseconds(Double(milliseconds) * 1_000_000)
        case .microseconds(let microseconds):
            return clampedNanoseconds(Double(microseconds) * 1_000)
        case .nanoseconds(let nanoseconds):
            return clampedNanoseconds(Double(nanoseconds))
        case .never:
            return UInt64.max
        @unknown default:
            return 0
        }
    }
}
