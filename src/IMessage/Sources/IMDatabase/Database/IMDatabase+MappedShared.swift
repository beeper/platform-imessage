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

extension Row {
    borrowing func object(columnNames: [String]) throws -> [String: Any] {
        var result = [String: Any]()
        for (index, name) in columnNames.enumerated() {
            result[name] = try value(at: index)
        }
        return result
    }

    borrowing func value(at index: Int) throws -> Any {
        switch self[index].type {
        case .integer:
            return try self[index].expectConverting(Int.self)
        case .float:
            return try self[index].expectConverting(Double.self)
        case .text:
            return try self[index].expect(String.self)
        case .blob:
            return try self[index].expect(Data.self)
        case .null:
            return NSNull()
        default:
            return NSNull()
        }
    }
}
