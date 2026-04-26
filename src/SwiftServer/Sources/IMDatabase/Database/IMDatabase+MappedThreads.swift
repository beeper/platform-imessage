import Foundation
import SQLite

public enum MappedThreadPageDirection: String {
    case after
    case before
}

public let mappedThreadsLimit = 25

public extension IMDatabase {
    func mappedThreadRows(
        cursor: String?,
        direction: MappedThreadPageDirection?,
        limit: Int = mappedThreadsLimit
    ) throws -> [[String: Any]] {
        let chatColumns = try tableColumns("chat")
        let withCursor = cursor.flatMap { Int($0) }.map { (cursor: $0, direction: direction ?? .before) }
        let comparisonOperator = withCursor.map { $0.direction == .after ? ">" : "<" }
        var sql = """
        SELECT
        \(chatSelectionSQL(chatColumns: chatColumns)),
        (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate,
        CAST((SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS TEXT) AS msgDateString,
        CAST(last_read_message_timestamp AS TEXT) AS dateLastMessageReadString
        FROM chat
        """
        if let comparisonOperator {
            sql += "\nWHERE msgDate \(comparisonOperator) ?"
        }
        sql += "\nORDER BY msgDate DESC\nLIMIT \(limit)"

        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        if let withCursor {
            try statement.bind(withCursor.cursor)
        }
        return try statement.mapRowsUntilDone { row in
            try row.object(columnNames: chatSelectionNames(chatColumns: chatColumns))
        }
    }

    func mappedThreadRow(guid: String) throws -> [String: Any]? {
        let chatColumns = try tableColumns("chat")
        let sql = """
        SELECT
        \(chatSelectionSQL(chatColumns: chatColumns)),
        (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate,
        CAST((SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS TEXT) AS msgDateString,
        CAST(last_read_message_timestamp AS TEXT) AS dateLastMessageReadString
        FROM chat
        WHERE chat.guid = ?
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(guid)
        return try statement.compactMapRowsUntilDone { row in
            try row.object(columnNames: chatSelectionNames(chatColumns: chatColumns))
        }.first
    }

    func mappedThreadParticipantRows(chatRowIDs: [Int]) throws -> [Int: [[String: Any]]] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let sql = """
        SELECT chj.chat_id AS chat_id, uncanonicalized_id, id AS participantID
        FROM handle
        LEFT JOIN chat_handle_join AS chj ON chj.handle_id = handle.ROWID
        WHERE chat_id IN (\(chatRowIDs.map { _ in "?" }.joined(separator: ", ")))
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(chatRowIDs.map { $0 as any SQLiteBindable })
        let rows = try statement.mapRowsUntilDone { row in
            try row.object(columnNames: ["chat_id", "uncanonicalized_id", "participantID"])
        }
        return rows.reduce(into: [:]) { result, row in
            result[(row["chat_id"] as? Int) ?? -1, default: []].append(row)
        }
    }

    func mappedUnreadCounts() throws -> [Int: Int] {
        let sql = """
        SELECT
          cm.chat_id AS chat_id, COUNT(cm.chat_id) AS unread_count
        FROM
          message m
          INNER JOIN chat_message_join cm ON m.ROWID = cm.message_id
        WHERE
          m.item_type == 0
          AND m.is_read == 0
          AND m.is_from_me == 0
        GROUP BY
          cm.chat_id
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        return try statement.mapRowsUntilDone { row in
            (try row[0].expectConverting(Int.self), try row[1].expectConverting(Int.self))
        }.reduce(into: [:]) { result, pair in
            result[pair.0] = pair.1
        }
    }
}

private extension IMDatabase {
    func tableColumns(_ tableName: String) throws -> [String] {
        let statement = try Statement.prepare(escapedSQL: "PRAGMA table_info(\(tableName))", for: database)
        return try statement.mapRowsUntilDone { row in
            try row[1].expect(String.self)
        }
    }
}

private func chatSelectionNames(chatColumns: [String]) -> [String] {
    ["ROWID"] + chatColumns.filter { $0 != "ROWID" } + ["msgDate", "msgDateString", "dateLastMessageReadString"]
}

private func chatSelectionSQL(chatColumns: [String]) -> String {
    var selections = ["chat.ROWID AS ROWID"]
    selections += chatColumns
        .filter { $0 != "ROWID" }
        .map { "chat.\($0) AS \($0)" }
    return selections.joined(separator: ",\n")
}

private extension Row {
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
            let data = try self[index].expect(Data.self)
            return "data:;base64,\(data.base64EncodedString())"
        case .null:
            return NSNull()
        default:
            return NSNull()
        }
    }
}
