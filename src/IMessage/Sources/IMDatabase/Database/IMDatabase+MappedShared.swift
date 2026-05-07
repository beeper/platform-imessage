import Foundation
import GRDB

extension Database {
    func tableColumns(_ tableName: String) throws -> [String] {
        try Row.fetchAll(self, SQLRequest<Row>(sql: "PRAGMA table_info(\(tableName))", cached: true)).map { row in
            row[1] as String
        }
    }
}

extension IMDatabase {
    func tableColumns(_ tableName: String) throws -> [String] {
        if let cached = tableColumnCache[tableName] {
            return cached
        }
        let columns = try read { db in
            try db.tableColumns(tableName)
        }
        tableColumnCache[tableName] = columns
        return columns
    }
}

func sqlArguments(_ values: [Any]) -> StatementArguments {
    guard let arguments = StatementArguments(values) else {
        preconditionFailure("all SQL arguments must be database values")
    }
    return arguments
}

func fetchOneCached<T: DatabaseValueConvertible>(
    _ type: T.Type,
    db: Database,
    sql: String,
    arguments: StatementArguments = StatementArguments()
) throws -> T? {
    try T.fetchOne(db, SQLRequest<T>(sql: sql, arguments: arguments, cached: true))
}

func fetchAllRowsCached(
    db: Database,
    sql: String,
    arguments: StatementArguments = StatementArguments()
) throws -> [Row] {
    try Row.fetchAll(db, SQLRequest<Row>(sql: sql, arguments: arguments, cached: true))
}

func fetchCursorRowsCached(
    db: Database,
    sql: String,
    arguments: StatementArguments = StatementArguments()
) throws -> RowCursor {
    try Row.fetchCursor(db, SQLRequest<Row>(sql: sql, arguments: arguments, cached: true))
}
