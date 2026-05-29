import Foundation

// imessage db uses "nanoseconds since reference date" for its dates
public extension Date {
    var nanosecondsSinceReferenceDate: Int {
        clampedSQLiteDateInteger(timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    var millisecondsSinceReferenceDate: Int {
        clampedSQLiteDateInteger(timeIntervalSinceReferenceDate * 1000)
    }

    init(millisecondsSinceReferenceDate millis: Int) {
        self = Date(timeIntervalSinceReferenceDate: Double(millis) / 1000)
    }

    init(nanosecondsSinceReferenceDate nanos: Int) {
        self = Date(timeIntervalSinceReferenceDate: Double(nanos) / 1_000_000_000)
    }

    init(nanosecondsSinceReferenceDate nanos: Int64) {
        self = Date(timeIntervalSinceReferenceDate: Double(nanos) / 1_000_000_000)
    }
}

// SQLite INTEGER is signed 64-bit, and malformed or extreme Messages dates can
// round outside Int when converted Date -> Double -> integer. Clamp at this DB
// boundary so rebinding cursors cannot trap the process.
private func clampedSQLiteDateInteger(_ value: Double) -> Int {
    guard value.isFinite else {
        if value.isNaN { return 0 }
        return value.sign == .minus ? Int.min : Int.max
    }

    if value >= Double(Int.max) { return Int.max }
    if value <= Double(Int.min) { return Int.min }
    return Int(value)
}
