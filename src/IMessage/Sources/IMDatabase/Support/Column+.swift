import Foundation
import SQLiteData

extension QueryDecoder {
    mutating func optionalString() throws -> String? {
        try decode(String.self)
    }

    mutating func optionalInt() throws -> Int? {
        try decode(Int.self)
    }

    mutating func optionalData() throws -> Data? {
        try decode(Data.self)
    }

    mutating func requiredString<RowType>(_ column: String, row: RowType.Type) throws -> String {
        guard let value = try optionalString() else {
            throw MappedDatabaseRowError.missingRequiredColumn(row: String(describing: row), column: column)
        }
        return value
    }

    mutating func requiredInt<RowType>(_ column: String, row: RowType.Type) throws -> Int {
        guard let value = try optionalInt() else {
            throw MappedDatabaseRowError.missingRequiredColumn(row: String(describing: row), column: column)
        }
        return value
    }

    mutating func imCoreDate() throws -> Date? {
        guard let nanoseconds = try optionalInt() else {
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

    mutating func looseBool() throws -> Bool {
        guard let integer = try optionalInt() else {
            return false
        }

        return integer == 1
    }
}
