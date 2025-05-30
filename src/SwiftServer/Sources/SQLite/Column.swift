import Foundation
import SQLite3

public struct Column: ~Copyable {
    let statement: Statement
    let index: Int32

    init(statement: Statement, index: Int32) {
        self.statement = statement
        self.index = index
    }

    public var type: `Type` {
        `Type`(rawValue: sqlite3_column_type(statement.handle, index))
    }
}

// MARK: - Casting the Column Value

// NOTE: these methods are all `consuming` to help express that the conversions
// are destructive[1]. this isn't strictly needed per se, but we ought to only
// do a single conversion anyways
//
// [1]: https://www.sqlite.org/c3ref/column_blob.html

public extension Column {
    /// Automatic conversion is performed.
    consuming func `as`(_: String.Type) -> String? {
        // copy TEXT content, because this pointer is invalidated when we step/reset
        guard let ptr = sqlite3_column_text(statement.handle, index) else { return nil }
        return String(cString: ptr)
    }

    /// Automatic conversion is performed. Returns `0` upon significant mismatch.
    consuming func `as`(_: Int.Type) -> Int {
        Int(sqlite3_column_int64(statement.handle, index))
    }

    /// Automatic conversion is performed. Returns `0` upon significant mismatch.
    consuming func `as`(_: Double.Type) -> Double {
        sqlite3_column_double(statement.handle, index)
    }

    /// Automatic conversion is performed.
    consuming func `as`(_: Data.Type) -> Data? {
        guard let beginning = sqlite3_column_blob(statement.handle, index) else {
            return nil
        }

        let length = sqlite3_column_bytes(statement.handle, index)
        // copy BLOB content, because this pointer is invalidated when we step/reset
        let buffer = UnsafeBufferPointer(start: beginning.assumingMemoryBound(to: UInt8.self), count: Int(length))
        return Data(buffer: buffer)
    }
}

public extension Column {
    struct `Type`: RawRepresentable, CaseIterable {
        public static var allCases: [Self] {
            [.integer, .float, .text, .blob, .null]
        }

        public let rawValue: Int32

        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        public static let integer = Self(rawValue: SQLITE_INTEGER)
        public static let float = Self(rawValue: SQLITE_FLOAT)
        public static let text = Self(rawValue: SQLITE_TEXT)
        public static let blob = Self(rawValue: SQLITE_BLOB)
        public static let null = Self(rawValue: SQLITE_NULL)
    }
}
