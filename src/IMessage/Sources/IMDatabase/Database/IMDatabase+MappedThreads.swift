import SQLiteData

public let mappedThreadsLimit = 25

public extension IMDatabase {
    func mappedThreadRows(
        cursor: String?,
        direction: MappedPageDirection?,
        limit: Int = mappedThreadsLimit
    ) throws -> [MappedChatRow] {
        let chatSchema = try schema().chat
        let withCursor = cursor.flatMap { Int($0) }.map { (cursor: $0, direction: direction ?? .before) }
        let comparisonOperator = withCursor.map { $0.direction == .after ? ">" : "<" }
        var sql = """
        SELECT
        \(chatSelectionSQL(chatSchema: chatSchema)),
        (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate
        FROM chat
        """
        if let comparisonOperator {
            sql += "\nWHERE msgDate \(comparisonOperator) ?"
        }
        sql += "\nORDER BY msgDate DESC\nLIMIT \(limit)"

        return try read { db in
            if let withCursor {
                return try MappedChatRow.fetchAllMapped(db, sql: sql, arguments: [withCursor.cursor])
            }
            return try MappedChatRow.fetchAllMapped(db, sql: sql)
        }
    }

    func mappedThreadRow(guid: String) throws -> MappedChatRow? {
        let chatSchema = try schema().chat
        let sql = """
        SELECT
        \(chatSelectionSQL(chatSchema: chatSchema)),
        (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate
        FROM chat
        WHERE chat.guid = ?
        """
        return try read { db in
            try MappedChatRow.fetchAllMapped(db, sql: sql, arguments: [guid]).first
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
        return try read { db in
            try MappedHandleRow.fetchAllMapped(db, sql: sql, arguments: chatRowIDs).reduce(into: [:]) { result, row in
                result[row.chatID ?? -1, default: []].append(row)
            }
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
        return try read { db in
            try fetchAllSQL(UnreadCountRow.self, db: db, sql: sql, arguments: chatRowIDs).map { row in
                (row.chatID, row.unreadCount)
            }.reduce(into: [:]) { result, pair in
                result[pair.0] = pair.1
            }
        }
    }
}

private func chatSelectionSQL(chatSchema: TableSchema<ChatTable>) -> String {
    mappedChatColumnNames.map {
        columnSelection($0, tableAlias: "chat", tableColumns: chatSchema.columns)
    }.joined(separator: ",\n")
}

private let mappedChatColumnNames = [
    "ROWID",
    "guid",
    "state",
    "properties",
    "chat_identifier",
    "room_name",
    "account_login",
    "last_addressed_handle",
    "display_name",
    "group_id",
    "last_read_message_timestamp",
]

private func columnSelection(_ column: String, tableAlias: String, tableColumns: [String]) -> String {
    if tableColumns.contains(column) {
        return "\(tableAlias).\(column) AS \(column)"
    }
    return "NULL AS \(column)"
}

private struct UnreadCountRow: QueryRepresentable {
    typealias QueryOutput = Self

    let chatID: Int
    let unreadCount: Int

    init(decoder: inout some QueryDecoder) throws {
        chatID = try decoder.requiredInt("chat_id", row: Self.self)
        unreadCount = try decoder.requiredInt("unread_count", row: Self.self)
    }
}
