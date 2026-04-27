import Foundation
import SQLite

public enum MappedMessagePageDirection: String {
    case after
    case before
}

private let messageJoins = """
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
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
        direction: MappedMessagePageDirection?,
        limit: Int = 20
    ) throws -> [MappedMessageRow] {
        let messageColumns = try tableColumns("message")
        let withCursor = cursor.flatMap { Int($0) }.map { (cursor: $0, direction: direction ?? .before) }
        let comparisonOperator = withCursor.map { $0.direction == .after ? ">" : "<" }
        let order = withCursor?.direction == .after ? "ASC" : "DESC"
        let dateExpression = comparisonOperator == ">" && messageColumns.contains("date_edited")
            ? "MAX(m.date, COALESCE(m.date_edited, 0))"
            : "m.date"

        var sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM message AS m
        \(messageJoins)
        WHERE t.guid = ?
        """
        if let comparisonOperator {
            sql += "\nAND \(dateExpression) \(comparisonOperator) ?"
        }
        sql += "\nORDER BY m.date \(order)\nLIMIT \(limit)"

        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        if let withCursor {
            try statement.bind(chatGUID, withCursor.cursor)
        } else {
            try statement.bind(chatGUID)
        }

        return try statement.mapRowsUntilDone(MappedMessageRow.self)
    }

    func mappedMessageRow(guid: String) throws -> MappedMessageRow? {
        let messageColumns = try tableColumns("message")
        let sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM message AS m
        \(messageJoins)
        WHERE m.guid = ?
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(guid)
        return try statement.mapRowsUntilDone(MappedMessageRow.self).first
    }

    func mappedMessageRows(rowIDs: [Int]) throws -> [MappedMessageRow] {
        guard !rowIDs.isEmpty else { return [] }
        let messageColumns = try tableColumns("message")
        let sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM message AS m
        \(messageJoins)
        WHERE m.ROWID IN (\(rowIDs.map { _ in "?" }.joined(separator: ", ")))
        ORDER BY m.date DESC
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(rowIDs.map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone(MappedMessageRow.self)
    }

    func mappedLatestMessageRows(chatRowIDs: [Int]) throws -> [String: MappedMessageRow] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let messageColumns = try tableColumns("message")
        let placeholders = chatRowIDs.map { _ in "?" }.joined(separator: ", ")
        let sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM message AS m
        \(messageJoins)
        WHERE cmj.chat_id IN (\(placeholders))
        AND m.ROWID = (
          SELECT latest.message_id
          FROM chat_message_join AS latest
          INNER JOIN message AS latest_message ON latest_message.ROWID = latest.message_id
          WHERE latest.chat_id = cmj.chat_id
          ORDER BY latest_message.date DESC
          LIMIT 1
        )
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
        WHERE m.ROWID IN (\(messageRowIDs.map { _ in "?" }.joined(separator: ", ")))
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
