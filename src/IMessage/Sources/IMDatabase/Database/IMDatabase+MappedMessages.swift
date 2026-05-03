import Foundation
import IMessageCore
import SQLite

private let messageJoins = """
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
\(messageHandleJoins)
"""

private let messageJoinsFromChatMessageJoin = """
INNER JOIN message AS m ON m.ROWID = cmj.message_id
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
\(messageHandleJoins)
"""

private let latestMessageJoins = """
INNER JOIN message AS m ON m.ROWID = latest_join.message_id
LEFT JOIN chat AS t ON latest_join.chat_id = t.ROWID
\(messageHandleJoins)
"""

private let messageHandleJoins = """
LEFT JOIN handle AS h ON m.handle_id = h.ROWID
LEFT JOIN handle AS oh ON m.other_handle = oh.ROWID
"""

public extension IMDatabase {
    func lastMessageRowID() throws -> Int {
        let statement = try cachedStatement(forEscapedSQL: "SELECT seq FROM sqlite_sequence WHERE name = 'message'").reset()
        return try statement.compactMapRowsUntilDone { row in
            try row[0].optionalConverting(Int.self)
        }.first ?? 0
    }

    func maxMessageDateRead() throws -> Date {
        let statement = try cachedStatement(forEscapedSQL: "SELECT MAX(date_read) FROM message").reset()
        let nanoseconds = try statement.compactMapRowsUntilDone { row in
            try row[0].optionalConverting(Int.self)
        }.first ?? 0

        guard nanoseconds > 0, nanoseconds < .max else {
            return Date(nanosecondsSinceReferenceDate: 0)
        }

        return Date(nanosecondsSinceReferenceDate: nanoseconds)
    }

    func sentMessageIDs(since rowID: Int) throws -> [(rowID: Int, guid: String)] {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT ROWID, guid
        FROM message
        WHERE is_from_me = 1 AND ROWID > ?
        """).reset()
        try statement.bind(rowID)
        return try statement.compactMapRowsUntilDone { row in
            guard let rowID = try row[0].optionalConverting(Int.self),
                  let guid = try row[1].optionalConverting(String.self) else {
                return nil
            }
            return (rowID, guid)
        }
    }

    func threadIDForMessage(rowID: Int) throws -> String? {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT t.guid
        FROM message AS m
        LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
        WHERE m.ROWID = ?
        """).reset()
        try statement.bind(rowID)
        return try statement.compactMapRowsUntilDone { row in
            try row[0].optionalConverting(String.self)
        }.first
    }

    func allThreadGUIDs() throws -> [String] {
        let statement = try cachedStatement(forEscapedSQL: "SELECT guid FROM chat").reset()
        return try statement.compactMapRowsUntilDone { row in
            try row[0].optional(String.self)
        }
    }

    func mappedMessageRows(
        in chatGUID: String,
        cursor: String?,
        direction: MappedPageDirection?,
        limit: Int = 20
    ) throws -> [MappedMessageRow] {
        let messageColumns = try tableColumns("message")
        let withCursor = cursor.flatMap { Int($0) }.map { (cursor: $0, direction: direction ?? .before) }
        let comparisonOperator = withCursor.map { $0.direction == .after ? ">" : "<" }
        let order = withCursor?.direction == .after ? "ASC" : "DESC"
        let dateExpression = comparisonOperator == ">" && messageColumns.contains("date_edited")
            ? "MAX(m.date, COALESCE(m.date_edited, 0))"
            : "cmj.message_date"

        // The historical query filtered by chat guid after starting from
        // `message ORDER BY date`. On large databases that can walk a huge
        // date index to find a sparse chat. Starting from chat_message_join's
        // chat_id/date indexes touches only the requested chat's messages.
        guard let chatRowID = try mappedChatRowID(guid: chatGUID) else {
            return []
        }

        var sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM chat_message_join AS cmj
        \(messageJoinsFromChatMessageJoin)
        WHERE cmj.chat_id = ?
        """
        if let comparisonOperator {
            sql += "\nAND \(dateExpression) \(comparisonOperator) ?"
        }
        sql += "\nORDER BY cmj.message_date \(order), cmj.message_id \(order)\nLIMIT \(limit)"

        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        if let withCursor {
            try statement.bind(chatRowID, withCursor.cursor)
        } else {
            try statement.bind(chatRowID)
        }

        return try statement.mapRowsUntilDone(MappedMessageRow.self)
    }

    func mappedChatRowID(guid: String) throws -> Int? {
        let statement = try cachedStatement(forEscapedSQL: "SELECT ROWID FROM chat WHERE guid = ?").reset()
        try statement.bind(guid)
        return try statement.compactMapRowsUntilDone { row in
            try row[0].optionalConverting(Int.self)
        }.first
    }

    func mappedMessageRow(guid: String) throws -> MappedMessageRow? {
        try mappedMessageRows(guids: [guid]).first
    }

    func mappedMessageRows(guids: [String]) throws -> [MappedMessageRow] {
        guard !guids.isEmpty else { return [] }
        guard guids.count <= maxMappedMessageRowsBatchSize else {
            return try guids
                .chunks(ofCount: maxMappedMessageRowsBatchSize)
                .flatMap { try mappedMessageRows(guids: Array($0)) }
        }

        let messageColumns = try tableColumns("message")
        let sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM message AS m
        \(messageJoins)
        WHERE m.guid IN (\(placeholders(count: guids.count)))
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(guids.map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone(MappedMessageRow.self)
    }

    func mappedMessageRows(rowIDs: [Int]) throws -> [MappedMessageRow] {
        guard !rowIDs.isEmpty else { return [] }
        guard rowIDs.count <= maxMappedMessageRowsBatchSize else {
            return try rowIDs
                .chunks(ofCount: maxMappedMessageRowsBatchSize)
                .flatMap { try mappedMessageRows(rowIDs: Array($0)) }
                .sorted { ($0.date ?? 0) > ($1.date ?? 0) }
        }

        let messageColumns = try tableColumns("message")
        let sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM message AS m
        \(messageJoins)
        WHERE m.ROWID IN (\(placeholders(count: rowIDs.count)))
        ORDER BY m.date DESC
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(rowIDs.map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone(MappedMessageRow.self)
    }

    func mappedLatestMessageRows(chatRowIDs: [Int]) throws -> [String: MappedMessageRow] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let messageColumns = try tableColumns("message")
        let sql = """
        WITH requested_chat(rowid) AS (
          VALUES \(rowValuePlaceholders(count: chatRowIDs.count))
        ),
        latest_join AS (
          SELECT
            requested_chat.rowid AS chat_id,
            (
              SELECT cmj.message_id
              FROM chat_message_join AS cmj
              WHERE cmj.chat_id = requested_chat.rowid
              ORDER BY cmj.message_date DESC, cmj.message_id DESC
              LIMIT 1
            ) AS message_id
          FROM requested_chat
        )
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM latest_join
        \(latestMessageJoins)
        ORDER BY m.date DESC
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(chatRowIDs.map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone(MappedMessageRow.self).reduce(into: [:]) { result, messageRow in
            guard let threadID = messageRow.threadID else { return }
            result[threadID] = messageRow
        }
    }

    func mappedAttachmentRows(messageRowIDs: [Int]) throws -> [MappedAttachmentRow] {
        guard !messageRowIDs.isEmpty else { return [] }
        let sql = """
        SELECT m.ROWID AS msgRowID, a.filename, a.transfer_name, a.total_bytes, a.is_sticker, a.guid AS attachmentID, a.transfer_state
        FROM message AS m
        LEFT JOIN message_attachment_join AS maj ON maj.message_id = m.ROWID
        LEFT JOIN attachment AS a ON a.ROWID = maj.attachment_id
        WHERE m.ROWID IN (\(placeholders(count: messageRowIDs.count)))
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(messageRowIDs.map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone(MappedAttachmentRow.self)
    }

    func attachmentFilename(guid: String) throws -> String? {
        let statement = try cachedStatement(forEscapedSQL: "SELECT filename FROM attachment WHERE guid = ?").reset()
        try statement.bind(guid)
        return try statement.compactMapRowsUntilDone { row in
            try row[0].optional(String.self)
        }.first
    }

    func attachmentFilename(messageRowID: Int) throws -> String? {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT a.filename FROM message_attachment_join AS maj
        INNER JOIN attachment AS a ON a.ROWID = maj.attachment_id
        WHERE maj.message_id = ?
        """).reset()
        try statement.bind(messageRowID)
        return try statement.compactMapRowsUntilDone { row in
            try row[0].optional(String.self)
        }.first
    }

    func mappedReactionRows(messageGUIDs: [String], chatRowIDs: [Int]) throws -> [MappedReactionMessageRow] {
        guard !messageGUIDs.isEmpty, !chatRowIDs.isEmpty else { return [] }
        let messageColumns = try tableColumns("message")
        let emojiColumn = messageColumns.contains("associated_message_emoji") ? "associated_message_emoji," : ""
        let messageGUIDPlaceholders = messageGUIDs.map { _ in "?" }.joined(separator: ",")
        let chatRowIDPlaceholders = chatRowIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT m.ROWID, is_from_me, handle_id, associated_message_type, associated_message_guid, \(emojiColumn) h.id AS participantID
        FROM message AS m
        LEFT JOIN handle AS h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
        WHERE REPLACE(SUBSTR(associated_message_guid, INSTR(associated_message_guid, '/') + 1), 'bp:', '') IN (\(messageGUIDPlaceholders))
        AND cmj.chat_id IN (\(chatRowIDPlaceholders))
        ORDER BY m.ROWID ASC
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        var bindings = messageGUIDs.map { $0 as any SQLiteBindable }
        bindings.append(contentsOf: chatRowIDs.map { $0 as any SQLiteBindable })
        try statement.bind(bindings)
        return try statement.mapRowsUntilDone(MappedReactionMessageRow.self)
    }

    func mappedReactionRows(messageGUIDs: [String], chatRowID: Int) throws -> [MappedReactionMessageRow] {
        try mappedReactionRows(messageGUIDs: messageGUIDs, chatRowIDs: [chatRowID])
    }

    func mappedReactionRows(messageGUIDs: [String], chatGUID: String) throws -> [MappedReactionMessageRow] {
        guard let chatRowID = try chat(withGUID: chatGUID)?.id else {
            return []
        }
        return try mappedReactionRows(messageGUIDs: messageGUIDs, chatRowID: chatRowID)
    }
}

private let maxMappedMessageRowsBatchSize = 500

private func messageSelectionSQL(messageColumns: [String]) -> String {
    var selections = ["m.ROWID AS ROWID"]
    selections += messageColumns
        .filter { $0 != "ROWID" }
        .map { "m.\($0) AS \($0)" }
    selections += [
        "t.guid AS threadID",
        "t.ROWID AS chatRowID",
        "t.room_name",
        "h.id AS participantID",
        "oh.id AS otherID",
    ]
    return selections.joined(separator: ",\n")
}

private func placeholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}

private func rowValuePlaceholders(count: Int) -> String {
    Array(repeating: "(?)", count: count).joined(separator: ", ")
}
