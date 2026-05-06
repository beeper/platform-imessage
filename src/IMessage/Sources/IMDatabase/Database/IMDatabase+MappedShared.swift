import Foundation
import GRDB

extension Database {
    func tableColumns(_ tableName: String) throws -> [String] {
        try Row.fetchAll(self, sql: "PRAGMA table_info(\(tableName))").map { row in
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
