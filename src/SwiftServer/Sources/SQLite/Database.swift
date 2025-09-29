import Darwin
import Logging
import SQLite3

private let log = Logger(label: "sqlite")

public final class Database {
    var connection: OpaquePointer?

    public struct OpenFlags: RawRepresentable, OptionSet {
        public let rawValue: Int32

        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        public static let readOnly = Self(rawValue: SQLITE_OPEN_READONLY)
        public static let readWrite = Self(rawValue: SQLITE_OPEN_READWRITE)
        public static let createIfNecessary = Self(rawValue: SQLITE_OPEN_CREATE)
        public static let interpretAsURI = Self(rawValue: SQLITE_OPEN_URI)
        public static let inMemory = Self(rawValue: SQLITE_OPEN_MEMORY)
        public static let withoutFollowingSymbolicLinks = Self(rawValue: SQLITE_OPEN_NOFOLLOW)
    }

    public init(connecting connectionString: String, flags: OpenFlags) throws {
        let connectionString = connectionString
        try connectionString.withCString { connectionString in
            _ = try SQLiteError.check(sqlite3_open_v2(connectionString, &connection, flags.rawValue, nil))
        }
        log.debug("connected to \(connectionString)")
    }

    deinit {
        log.debug("closing database connection")
        try! SQLiteError.check(sqlite3_close_v2(connection))
    }
}

public extension Database {
    func execute<each T: SQLiteBindable>(sqlWithoutEscaping sql: String, _ bindingValue: repeat each T) throws {
        let statement = try Statement.prepare(escapedSQL: sql, for: self)
        try statement.bind(repeat each bindingValue)
        try statement.stepUntilDone(handlingRows: { _ in })
    }
}
