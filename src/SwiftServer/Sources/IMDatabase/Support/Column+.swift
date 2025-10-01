import Foundation
import SQLite

extension Column {
    consuming func imCoreDate() throws -> Date? {
        guard let nanoseconds = try optionalConverting(Int.self) else {
            return nil
        }

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

    consuming func looseBool() throws -> Bool {
        guard let integer = try optionalConverting(Int.self) else {
            return false
        }

        return integer == 1
    }
}
