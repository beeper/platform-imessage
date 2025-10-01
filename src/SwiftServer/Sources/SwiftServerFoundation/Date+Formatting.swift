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

public extension Date? {
    var formattedForDebugging: String {
        guard let self else {
            return "(no date)"
        }

        if #available(macOS 12, *) {
            let relative = self.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            let absolute = self.formatted(Date.FormatStyle(date: .abbreviated, time: .complete))
            return "\(absolute) (\(relative))"
        } else {
            return "\(self)"
        }
    }
}
