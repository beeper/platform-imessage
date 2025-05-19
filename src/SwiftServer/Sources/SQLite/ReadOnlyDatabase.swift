import SQLite3
import Logging

private let log = Logger(label: "sws.sqlite.rodb")

public struct SQLiteError: Error {
    let code: Int
    let localizedDescription: String

    public init(code: CInt) {
        self.code = Int(code)
        localizedDescription = if let pointer = sqlite3_errstr(code) {
            String(cString: pointer)
        } else {
            "<no message>"
        }
    }

    static func check(_ error: CInt) throws {
        guard error == SQLITE_OK else {
            throw Self(code: error)
        }
    }
}

public class ReadOnlyDatabase {
    var connection: OpaquePointer?

    public init(connecting connectionString: String) throws {
        var connectionString = connectionString
        try connectionString.withCString { connectionString in
            try SQLiteError.check(sqlite3_open_v2(connectionString, &connection, SQLITE_OPEN_READONLY, nil))
        }
        log.debug("connected to \(connectionString)")
    }

    deinit {
        log.debug("closing connection")
        precondition(sqlite3_close_v2(connection) == SQLITE_OK, "couldn't close sqlite connection")
    }
}
