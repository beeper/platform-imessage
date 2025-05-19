import Foundation
import SQLite3

/// A convenience type to pull ``Column``s out of a queried row.
///
/// Values of this type are noncopyable in order to statically prevent the
/// instance from escaping out of a single `sqlite3_step`.
public struct Row: ~Copyable {
    let statement: Statement

    init(accessingColumnsOf statement: Statement) {
        self.statement = statement
    }

    public subscript(_ columnIndex: Int) -> Column {
        precondition(columnIndex >= 0 && columnIndex < statement.columnCount, "column index \(columnIndex) is out of range (column count is \(statement.columnCount))")
        return Column(statement: statement, index: Int32(columnIndex))
    }
}
