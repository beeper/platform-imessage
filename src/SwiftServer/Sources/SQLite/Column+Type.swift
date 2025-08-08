import SQLite3

public extension Column {
    /// Returns the initial data type for this column (NOT necessarily the
    /// declared type in the schema).
    ///
    /// It's undefined behavior to read this property after performing a type
    /// conversion.
    var type: `Type` {
        `Type`(rawValue: sqlite3_column_type(statement.handle, index))
    }

    struct `Type`: RawRepresentable, CaseIterable, Equatable {
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

extension Column.`Type`: CustomStringConvertible {
    public var description: String {
        // see: https://www.sqlite.org/c3ref/c_blob.html
        switch rawValue {
        case SQLITE_INTEGER: "integer"
        case SQLITE_FLOAT: "float"
        case SQLITE_TEXT: "text"
        case SQLITE_BLOB: "blob"
        case SQLITE_NULL: "null"
        default: "<unknown>"
        }
    }
}

// MARK: - Helpers

extension Column {
    func _expectSpecific(_ desired: Type, sourceLocation: @autoclosure (() -> SourceLocation)) throws(Error) {
        guard type == desired else {
            throw .expectedSpecificType(columnIndex: index, desired: desired, actual: type, sourceLocation: sourceLocation())
        }
    }

    func _expectNonNull(preferring preference: Type? = nil, sourceLocation: @autoclosure (() -> SourceLocation)) throws(Error) {
        guard type != .null else {
            throw .expectedSomeNonNull(columnIndex: index, preference: preference, sourceLocation: sourceLocation())
        }
    }
}
