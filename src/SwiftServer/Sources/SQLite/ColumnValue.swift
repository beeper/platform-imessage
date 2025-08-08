import Foundation
import SQLite3

public protocol ColumnValue {
    static var preferredDataType: Column.`Type` { get }

    static func readNonNullConverting(from statement: OpaquePointer, at index: Column.Index) throws(Column.Error) -> Self
}

extension String: ColumnValue {
    public static let preferredDataType: Column.`Type` = .text

    public static func readNonNullConverting(
        from statement: OpaquePointer,
        at index: Column.Index,
    ) throws(Column.Error) -> String {
        guard let ptr = sqlite3_column_text(statement, index) else { throw .outOfMemory }
        return String(cString: ptr)
    }
}

extension Int: ColumnValue {
    public static let preferredDataType: Column.`Type` = .integer

    public static func readNonNullConverting(
        from statement: OpaquePointer,
        at index: Column.Index,
    ) throws(Column.Error) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }
}

extension Double: ColumnValue {
    public static let preferredDataType: Column.`Type` = .float

    public static func readNonNullConverting(
        from statement: OpaquePointer,
        at index: Column.Index,
    ) throws(Column.Error) -> Double {
        sqlite3_column_double(statement, index)
    }
}

extension Data: ColumnValue {
    public static let preferredDataType: Column.`Type` = .blob

    public static func readNonNullConverting(
        from statement: OpaquePointer,
        at index: Column.Index,
    ) throws(Column.Error) -> Data {
        let length = sqlite3_column_bytes(statement, index)

        // `sqlite3_column_blob` returns `NULL` for zero-length BLOBs; take care
        // to detect this specifically as to differentiate it from a memory
        // error
        guard length > 0 else { return Data() }

        guard let beginning = sqlite3_column_blob(statement, index) else { throw .outOfMemory }

        let buffer = UnsafeBufferPointer(start: beginning.assumingMemoryBound(to: UInt8.self), count: Int(length))
        // copy BLOB content, because this pointer is invalidated when we step/reset
        return Data(buffer: buffer)
    }
}
