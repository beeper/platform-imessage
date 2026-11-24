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

    func hasRecoverableMessageJoin() throws -> Bool {
        try !tableColumns("chat_recoverable_message_join").isEmpty
    }
}

// Same predicate as Apple's unread indexes (macOS 26+); expects `message AS m`.
let unreadCandidatePredicateSQL = "m.is_from_me = 0 AND m.item_type = 0 AND m.is_finished = 1 AND m.is_system_message = 0"
