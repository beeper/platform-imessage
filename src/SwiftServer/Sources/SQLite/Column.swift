import Foundation
import SQLite3

public struct Column: ~Copyable {
    public typealias Index = Int32

    let statement: Statement
    let index: Index

    init(statement: Statement, index: Index) {
        self.statement = statement
        self.index = index
    }
}

// MARK: - Errors

public extension Column {
    // equatable for the tests
    enum Error: Swift.Error, Equatable {
        case expectedSpecificType(columnIndex: Int32, desired: Type, actual: Type, sourceLocation: SourceLocation)
        case expectedSomeNonNull(columnIndex: Int32, preference: Type?, sourceLocation: SourceLocation)
        case outOfMemory
    }
}

extension Column.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .expectedSpecificType(columnIndex, desired, actual, sourceLocation):
            "expected \(desired) in column \(columnIndex), is actually \(actual) \(sourceLocation)"
        case let .expectedSomeNonNull(columnIndex, preference, sourceLocation):
            if let preference {
                "expected some non-null in column \(columnIndex) (casting to \(preference)), is actually null \(sourceLocation)"
            } else {
                "expected some non-null in column \(columnIndex), is actually null \(sourceLocation)"
            }
        case .outOfMemory: "out of memory"
        }
    }
}

// MARK: - Casting the Column Value

// NOTE: these methods are all `consuming` to help express that the conversions
// are destructive[1]. this isn't strictly needed per se, but we ought to only
// do a single conversion anyways
//
// [1]: https://www.sqlite.org/c3ref/column_blob.html

public extension Column {
    /// Expects a non-`NULL` value in this column, returning the requested type via automatic conversion.
    consuming func expectConverting<Value: ColumnValue>(_: Value.Type, _ file: StaticString = #fileID, line: Int = #line) throws(Column.Error) -> Value {
        try _expectNonNull(preferring: Value.preferredDataType, sourceLocation: SourceLocation(opaque: "\(file):\(line)"))
        return try Value.readNonNullConverting(from: statement.handle, at: index)
    }

    /// Expects a non-`NULL` value of a specific type in this column.
    consuming func expect<Value: ColumnValue>(_: Value.Type, _ file: StaticString = #fileID, line: Int = #line) throws(Column.Error) -> Value {
        try _expectSpecific(Value.preferredDataType, sourceLocation: SourceLocation(opaque: "\(file):\(line)"))
        return try Value.readNonNullConverting(from: statement.handle, at: index)
    }

    /// Requests the value of this column, converting to the requested type. `nil` is returned if the value is `NULL`.
    consuming func optionalConverting<Value: ColumnValue>(_: Value.Type, _ file: StaticString = #fileID, line: Int = #line) throws(Column.Error) -> Value? {
        guard type != .null else { return nil }
        try _expectSpecific(Value.preferredDataType, sourceLocation: SourceLocation(opaque: "\(file):\(line)"))
        return try Value.readNonNullConverting(from: statement.handle, at: index)
    }

    /// Requests the value of this column, expecting it to be a specific type. `nil` is returned if the value is `NULL`.
    consuming func optional<Value: ColumnValue>(_: Value.Type, _ file: StaticString = #fileID, line: Int = #line) throws(Column.Error) -> Value? {
        guard type != .null else { return nil }
        try _expectNonNull(preferring: Value.preferredDataType, sourceLocation: SourceLocation(opaque: "\(file):\(line)"))
        return try Value.readNonNullConverting(from: statement.handle, at: index)
    }
}
