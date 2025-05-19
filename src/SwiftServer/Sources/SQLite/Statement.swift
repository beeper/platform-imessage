import Logging
import SQLite3

private let log = Logger(label: "sqlite.rodb.stmt")

public final class Statement {
    var handle: OpaquePointer
    var database: ReadOnlyDatabase

    init(handle: OpaquePointer, database: ReadOnlyDatabase) {
        self.handle = handle
        self.database = database
    }

    deinit {
        log.debug("finalizing prepared statement")
        try! SQLiteError.check(sqlite3_finalize(handle))
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

// MARK: - Resetting, Clearing, Binding, and Stepping

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

    func stepUntilDone(handlingRows rowHandler: (_ selected: borrowing Row) throws -> Void) throws {
        defer { try! SQLiteError.check(sqlite3_reset(handle)) }

        while try SQLiteError.check(sqlite3_step(handle), permitting: [SQLITE_ROW, SQLITE_DONE]) == SQLITE_ROW {
            try rowHandler(Row(accessingColumnsOf: self))
        }
    }
}
