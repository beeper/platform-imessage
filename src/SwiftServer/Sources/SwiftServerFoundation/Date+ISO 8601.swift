import Foundation

private let iso8601DateFormatter = {
    var formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
    return formatter
}()

public extension Date {
    var iso8601Formatted: String {
        iso8601DateFormatter.string(from: self)
    }
}

