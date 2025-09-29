import Logging
import Darwin
import SQLite3

private let log = Logger(label: "sqlite.stmt")

public final class Statement {
    var handle: OpaquePointer
    var database: Database

    public static func prepare(escapedSQL sql: String, for database: Database, flags: PrepareFlags = []) throws -> Statement {
        precondition(!sql.isEmpty, "can't prepare an empty SQL statement")

        var statement: OpaquePointer?

        try sql.withCString { ptr in
            _ = try SQLiteError.check(sqlite3_prepare_v3(database.connection, ptr, Int32(strlen(ptr)), flags.rawValue, &statement, nil))
        }

        guard let statement else {
            preconditionFailure("sqlite3_prepare_v3 didn't give us a statement")
        }

#if DEBUG
        log.debug("prepared: \"\(sql)\"")
#endif

        return Statement(handle: statement, database: database)
    }

    init(handle: OpaquePointer, database: Database) {
        self.handle = handle
        self.database = database
    }

    deinit {
        log.debug("finalizing prepared statement")
        try! SQLiteError.check(sqlite3_finalize(handle))
    }
}

public extension Statement {
    struct PrepareFlags: OptionSet {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let persistent = Self(rawValue: UInt32(SQLITE_PREPARE_PERSISTENT))
    }
}

// MARK: - Accessing Counts

public extension Statement {
    var parameterCount: Int {
        Int(sqlite3_bind_parameter_count(handle))
    }

    var columnCount: Int {
        Int(sqlite3_column_count(handle))
    }
}

// MARK: - Resetting, Clearing, and Binding

public extension Statement {
    func reset() throws {
        try SQLiteError.check(sqlite3_reset(handle))
    }

    func clearBindings() throws {
        try SQLiteError.check(sqlite3_clear_bindings(handle))
    }

    func bind<each T: SQLiteBindable>(_ values: repeat each T) throws {
        var currentParameterIndex: Int32 = 1
        for binding in repeat each values {
            precondition(currentParameterIndex <= parameterCount, "tried to bind \(currentParameterIndex) value(s) (maximum is \(parameterCount))")
            defer { currentParameterIndex += 1 }
            try binding.unsafeBind(toPreparedStatement: handle, at: currentParameterIndex)
        }
    }
}

// MARK: - Stepping

public extension Statement {
    func stepUntilDone(handlingRows rowHandler: (_ selected: borrowing Row) throws -> Void) throws {
        defer { try! SQLiteError.check(sqlite3_reset(handle)) }

        while try SQLiteError.check(sqlite3_step(handle), permitting: [SQLITE_ROW, SQLITE_DONE]) == SQLITE_ROW {
            try rowHandler(Row(accessingColumnsOf: self))
        }
    }

    func mapRowsUntilDone<T>(_ transform: (_ row: borrowing Row) throws -> T) throws -> [T] {
        var results = [T]()
        try stepUntilDone {
            try results.append(transform($0))
        }
        return results
    }

    func compactMapRowsUntilDone<T>(_ transform: (_ row: borrowing Row) throws -> T?) throws -> [T] {
        var results = [T]()
        try stepUntilDone {
            if let result = try transform($0) {
                results.append(result)
            }
        }
        return results
    }
}
