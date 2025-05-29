import Foundation

// imessage db uses "nanoseconds since reference date" for its dates
public extension Date {
    var nanosecondsSinceReferenceDate: Int {
        Int(timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    init(nanosecondsSinceReferenceDate nanos: Int) {
        self = Date(timeIntervalSinceReferenceDate: Double(nanos) / 1_000_000_000)
    }
}
