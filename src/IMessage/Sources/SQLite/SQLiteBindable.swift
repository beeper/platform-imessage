import Darwin
import SQLite3

public protocol SQLiteBindable {
    func unsafeBind(toPreparedStatement handle: OpaquePointer, at parameterIndex: Int32) throws
}

extension String: SQLiteBindable {
    public func unsafeBind(toPreparedStatement handle: OpaquePointer, at parameterIndex: Int32) throws {
        try withCString { ptr in
            // tell SQLite to copy the string via SQLITE_TRANSIENT[1], because
            // it won't be valid outside of this closure
            //
            // [1]: https://www.sqlite.org/c3ref/c_static.html
            let SQLITE_TRANSIENT = -1
            typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void
            let transient = unsafeBitCast(SQLITE_TRANSIENT, to: SQLiteDestructor.self)

            try SQLiteError.check(sqlite3_bind_text(handle, parameterIndex, ptr, Int32(strlen(ptr)), transient))
        }
    }
}

extension Int: SQLiteBindable {
    public func unsafeBind(toPreparedStatement handle: OpaquePointer, at parameterIndex: Int32) throws {
        try SQLiteError.check(sqlite3_bind_int64(handle, parameterIndex, Int64(self)))
    }
}
