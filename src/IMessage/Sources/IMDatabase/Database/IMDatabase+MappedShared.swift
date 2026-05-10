import Foundation
import SQLiteData

extension Database {
    func tableColumns(_ tableName: String) throws -> [String] {
        try fetchAllSQL(String.self, db: self, sql: "SELECT name FROM pragma_table_info(?)", arguments: [tableName])
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

func fetchOneSQL<T: QueryRepresentable>(
    _ type: T.Type,
    db: Database,
    sql: String,
    arguments: [Any] = []
) throws -> T.QueryOutput? {
    try SQLQueryExpression<T>(sqlQuery(sql, arguments: arguments), as: T.self).fetchOne(db)
}

func fetchOneOptionalSQL<T: QueryRepresentable>(
    _ type: T.Type,
    db: Database,
    sql: String,
    arguments: [Any] = []
) throws -> T.QueryOutput? {
    try SQLQueryExpression<T?>(sqlQuery(sql, arguments: arguments), as: T?.self).fetchOne(db) ?? nil
}

func fetchAllSQL<T: QueryRepresentable>(
    _ type: T.Type,
    db: Database,
    sql: String,
    arguments: [Any] = []
) throws -> [T.QueryOutput] {
    try SQLQueryExpression<T>(sqlQuery(sql, arguments: arguments), as: T.self).fetchAll(db)
}

func fetchCursorSQL<T: QueryRepresentable>(
    _ type: T.Type,
    db: Database,
    sql: String,
    arguments: [Any] = []
) throws -> QueryCursor<T.QueryOutput> {
    try SQLQueryExpression<T>(sqlQuery(sql, arguments: arguments), as: T.self).fetchCursor(db)
}

func executeSQL(
    db: Database,
    sql: String,
    arguments: [Any] = []
) throws {
    try SQLQueryExpression<Void>(sqlQuery(sql, arguments: arguments)).execute(db)
}

func sqlArguments(_ values: [Any]) -> [Any] {
    values
}

func sqlQuery(_ sql: String, arguments: [Any] = []) -> QueryFragment {
    var query = QueryFragment()
    var remainder = sql[...]

    for argument in arguments.map(sqlBinding) {
        guard let placeholder = remainder.firstIndex(of: "?") else {
            preconditionFailure("more SQL arguments than placeholders")
        }
        query.append("\(raw: String(remainder[..<placeholder]))")
        query.append("\(argument)")
        remainder = remainder[remainder.index(after: placeholder)...]
    }

    precondition(!remainder.contains("?"), "fewer SQL arguments than placeholders")
    query.append("\(raw: String(remainder))")
    return query
}

private func sqlBinding(_ value: Any) -> QueryBinding {
    switch value {
    case let value as QueryBinding:
        value
    case let value as Int:
        value.queryBinding
    case let value as Int64:
        value.queryBinding
    case let value as String:
        value.queryBinding
    case let value as Bool:
        value.queryBinding
    case let value as Data:
        value.queryBinding
    case let value as GUID<Chat>:
        value.guts.queryBinding
    case let value as GUID<Message>:
        value.guts.queryBinding
    case let value as GUID<Attachment>:
        value.guts.queryBinding
    default:
        preconditionFailure("unsupported SQL argument type: \(type(of: value))")
    }
}
