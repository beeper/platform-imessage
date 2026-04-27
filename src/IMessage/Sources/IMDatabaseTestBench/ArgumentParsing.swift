import ArgumentParser
import Foundation
import IMDatabase
import Logging

extension Logger.Level: @retroactive ExpressibleByArgument {}

// MARK: - IMDatabase

extension DateOrdering: @retroactive ExpressibleByArgument {
    public static var allValueStrings: [String] {
        ["newest-first", "oldest-first"]
    }

    public static var allValueDescriptions: [String: String] {
        ["newest-first": "Newest messages first (date descending).", "oldest-first": "Oldest messages first (date ascending)."]
    }

    public init?(argument: String) {
        switch argument {
        case "newest-first": self = .newestFirst
        case "oldest-first": self = .oldestFirst
        default: return nil
        }
    }
}

extension MessageQueryFilter {
    @Sendable
    static func parse(_ input: String) throws -> Self {
        // (for `Date.FormatStyle`)
        guard #available(macOS 12, *) else {
            throw ValidationError("macOS 12 or later is required.")
        }

        guard let spaceIndex = input.firstIndex(of: " ") else {
            throw ValidationError("Malformed query filter. Examples: \"before <date>\", \"after <date>\".")
        }
        let word = input[..<spaceIndex]

        let rawDate = input[input.index(after: spaceIndex)...]
        let date = try Date.FormatStyle().day().month().year().hour().minute().second().parse(String(rawDate))

        switch word {
        case "before": return Self.before(date)
        case "after": return Self.after(date)
        default:
            throw ValidationError("Malformed query filter. \"\(word)\" isn't a valid filter. Try \"before\" or \"after\".")
        }
    }
}
