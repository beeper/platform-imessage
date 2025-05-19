import Darwin
import Logging
import SQLite3

private let log = Logger(label: "sqlite.rodb")

public final class ReadOnlyDatabase {
    var connection: OpaquePointer?

    public init(connecting connectionString: String) throws {
        let connectionString = connectionString
        try connectionString.withCString { connectionString in
            _ = try SQLiteError.check(sqlite3_open_v2(connectionString, &connection, SQLITE_OPEN_READONLY, nil))
        }
        log.debug("connected to \(connectionString)")
    }

    deinit {
        log.debug("closing database connection")
        try! SQLiteError.check(sqlite3_close_v2(connection))
    }
}

public extension ReadOnlyDatabase {
    struct PrepareFlags: OptionSet {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let persistent = Self(rawValue: UInt32(SQLITE_PREPARE_PERSISTENT))
    }

    func prepare(escapedSQL sql: String, flags: PrepareFlags) throws -> Statement {
        precondition(!sql.isEmpty, "can't prepare an empty SQL statement")

        var statement: OpaquePointer?
        try sql.withCString { ptr in
            _ = try SQLiteError.check(sqlite3_prepare_v3(connection, ptr, Int32(strlen(ptr)), flags.rawValue, &statement, nil))
        }

        guard let statement else {
            preconditionFailure("sqlite3_prepare_v3 didn't give us a statement")
        }
        return Statement(handle: statement, database: self)
    }
}
