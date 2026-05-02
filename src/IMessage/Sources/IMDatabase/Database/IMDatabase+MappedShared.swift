import Foundation
import SQLite

extension Database {
    func tableColumns(_ tableName: String) throws -> [String] {
        let statement = try Statement.prepare(escapedSQL: "PRAGMA table_info(\(tableName))", for: self)
        return try statement.mapRowsUntilDone { row in
            try row[1].expect(String.self)
        }
    }
}

extension IMDatabase {
    func tableColumns(_ tableName: String) throws -> [String] {
        if let cached = tableColumnCache[tableName] {
            return cached
        }
        let columns = try database.tableColumns(tableName)
        tableColumnCache[tableName] = columns
        return columns
    }
}
