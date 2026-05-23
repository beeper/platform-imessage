import Darwin
import Foundation
import SQLite3

private typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

private let sqliteTransient = unsafeBitCast(-1, to: SQLiteDestructor.self)

public protocol SQLiteBindable {
    func unsafeBind(toPreparedStatement handle: OpaquePointer, at parameterIndex: Int32) throws
}

extension String: SQLiteBindable {
    public func unsafeBind(toPreparedStatement handle: OpaquePointer, at parameterIndex: Int32) throws {
        _ = try withCString { ptr in
            // tell SQLite to copy the string via SQLITE_TRANSIENT[1], because
            // it won't be valid outside of this closure
            //
            // [1]: https://www.sqlite.org/c3ref/c_static.html
            try SQLiteError.check(sqlite3_bind_text(handle, parameterIndex, ptr, Int32(strlen(ptr)), sqliteTransient))
        }
    }
}

extension Data: SQLiteBindable {
    public func unsafeBind(toPreparedStatement handle: OpaquePointer, at parameterIndex: Int32) throws {
        guard !isEmpty else {
            try SQLiteError.check(sqlite3_bind_zeroblob(handle, parameterIndex, 0))
            return
        }

        _ = try withUnsafeBytes { buffer in
            try SQLiteError.check(sqlite3_bind_blob(handle, parameterIndex, buffer.baseAddress, Int32(count), sqliteTransient))
        }
    }
}

extension Int: SQLiteBindable {
    public func unsafeBind(toPreparedStatement handle: OpaquePointer, at parameterIndex: Int32) throws {
        try SQLiteError.check(sqlite3_bind_int64(handle, parameterIndex, Int64(self)))
    }
}
