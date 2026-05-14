import SQLite

public let mappedThreadsLimit = 25

public extension IMDatabase {
    func mappedThreadRows(
        cursor: String?,
        direction: MappedPageDirection?,
        limit: Int = mappedThreadsLimit
    ) throws -> [MappedChatRow] {
        let chatColumns = try tableColumns("chat")
        let withCursor = cursor.flatMap { Int($0) }.map { (cursor: $0, direction: direction ?? .before) }
        let comparisonOperator = withCursor.map { $0.direction == .after ? ">" : "<" }
        var sql = """
        SELECT
        \(chatSelectionSQL(chatColumns: chatColumns)),
        (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate
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
        return try statement.mapRowsUntilDone(MappedChatRow.self)
    }

    func mappedThreadRow(guid: String) throws -> MappedChatRow? {
        let chatColumns = try tableColumns("chat")
        let sql = """
        SELECT
        \(chatSelectionSQL(chatColumns: chatColumns)),
        (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate
        FROM chat
        WHERE chat.guid = ?
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(guid)
        return try statement.mapRowsUntilDone(MappedChatRow.self).first
    }

    func mappedExistingChatGUIDs(guids: [String]) throws -> [String] {
        guard !guids.isEmpty else { return [] }
        let sql = """
        SELECT chat.guid
        FROM chat
        WHERE chat.guid IN (\(guids.map { _ in "?" }.joined(separator: ", ")))
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(guids.map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone { row in
            try row[0].expect(String.self)
        }
    }

    func mappedThreadParticipantRows(chatRowIDs: [Int]) throws -> [Int: [MappedHandleRow]] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let sql = """
        SELECT chj.chat_id AS chat_id, uncanonicalized_id, id AS participantID
        FROM handle
        LEFT JOIN chat_handle_join AS chj ON chj.handle_id = handle.ROWID
        WHERE chat_id IN (\(chatRowIDs.map { _ in "?" }.joined(separator: ", ")))
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(chatRowIDs.map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone(MappedHandleRow.self).reduce(into: [:]) { result, row in
            result[row.chatID ?? -1, default: []].append(row)
        }
    }

    func mappedUnreadCounts(chatRowIDs: [Int]) throws -> [Int: Int] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let placeholders = chatRowIDs.map { _ in "?" }.joined(separator: ", ")
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
          AND cm.chat_id IN (\(placeholders))
        GROUP BY
          cm.chat_id
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(chatRowIDs.map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone { row in
            (try row[0].expectConverting(Int.self), try row[1].expectConverting(Int.self))
        }.reduce(into: [:]) { result, pair in
            result[pair.0] = pair.1
        }
    }
}

private func chatSelectionSQL(chatColumns: [String]) -> String {
    var selections = ["chat.ROWID AS ROWID"]
    selections += chatColumns
        .filter { $0 != "ROWID" }
        .map { "chat.\($0) AS \($0)" }
    return selections.joined(separator: ",\n")
}
