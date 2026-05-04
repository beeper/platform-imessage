import Foundation

// imessage db uses "nanoseconds since reference date" for its dates
public extension Date {
    var nanosecondsSinceReferenceDate: Int {
        Int(timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    var millisecondsSinceReferenceDate: Int {
        Int(timeIntervalSinceReferenceDate * 1000)
    }

    init(millisecondsSinceReferenceDate millis: Int) {
        self = Date(timeIntervalSinceReferenceDate: Double(millis) / 1000)
    }

    init(nanosecondsSinceReferenceDate nanos: Int) {
        self = Date(timeIntervalSinceReferenceDate: Double(nanos) / 1_000_000_000)
    }
}

extension Date {
    static func imCoreDate(nanoseconds: Int) -> Date? {
        // For unknown reasons `0` can be present instead of `NULL`. Treat them as the same.
        guard nanoseconds > 0 else {
            return nil
        }

        // Explicitly check for bogus dates. If you let these escape into the rest of the
        // program then an integer overflow might make everything implode.
        let date = Date(nanosecondsSinceReferenceDate: nanoseconds)
        guard date < .distantFuture else {
            return nil
        }

        return date
    }
}
