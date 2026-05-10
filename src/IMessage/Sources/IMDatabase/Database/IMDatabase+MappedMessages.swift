import Collections
import Foundation
import IMessageCore
import SQLiteData

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
        try read { db in
            try fetchOneSQL(Int.self, db: db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'message'") ?? 0
        }
    }

    func maxMessageDateRead() throws -> Date {
        let nanoseconds = try read { db in
            try fetchOneSQL(Int.self, db: db, sql: "SELECT MAX(date_read) FROM message") ?? 0
        }

        guard nanoseconds > 0, nanoseconds < .max else {
            return Date(nanosecondsSinceReferenceDate: 0)
        }

        return Date(nanosecondsSinceReferenceDate: nanoseconds)
    }

    func messageUpdateCursorSnapshot() throws -> (lastRowID: Int, lastDateRead: Date, lastDateEdited: Date) {
        let messageSchema = try schema().message
        let dateEditedSelection = messageSchema.has(.dateEdited)
            ? "COALESCE((SELECT MAX(\(MessageTable.Column.dateEdited.sqlName)) FROM \(MessageTable.sqlName)), 0)"
            : "0"
        let sql = """
        SELECT
            COALESCE((SELECT \(SQLiteSequenceTable.Column.seq.sqlName) FROM \(SQLiteSequenceTable.sqlName) WHERE \(SQLiteSequenceTable.Column.name.sqlName) = '\(MessageTable.sqlName)'), 0),
            COALESCE((SELECT MAX(\(MessageTable.Column.dateRead.sqlName)) FROM \(MessageTable.sqlName)), 0),
            \(dateEditedSelection)
        """

        return try read { db in
            try fetchAllSQL(MessageUpdateCursorSnapshotRow.self, db: db, sql: sql).map { row in
                (
                    lastRowID: row.lastRowID,
                    lastDateRead: row.lastDateRead ?? Date(nanosecondsSinceReferenceDate: 0),
                    lastDateEdited: row.lastDateEdited ?? Date(nanosecondsSinceReferenceDate: 0)
                )
            }.first
        } ?? (
            lastRowID: 0,
            lastDateRead: Date(nanosecondsSinceReferenceDate: 0),
            lastDateEdited: Date(nanosecondsSinceReferenceDate: 0)
        )
    }

    func sentMessageIDs(since rowID: Int) throws -> [(rowID: Int, guid: String)] {
        try read { db in
            try fetchAllSQL(SentMessageIDRow.self, db: db, sql: """
            SELECT ROWID, guid
            FROM message
            WHERE is_from_me = 1 AND ROWID > ?
            """, arguments: [rowID]).map { row in
                (rowID: row.rowID, guid: row.guid)
            }
        }
    }

    func threadIDForMessage(rowID: Int) throws -> String? {
        try read { db in
            try fetchOneOptionalSQL(String.self, db: db, sql: """
            SELECT t.guid
            FROM message AS m
            LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
            WHERE m.ROWID = ?
            """, arguments: [rowID])
        }
    }

    func allThreadGUIDs() throws -> [String] {
        try read { db in
            try fetchAllSQL(String?.self, db: db, sql: "SELECT guid FROM chat").compactMap(\.self)
        }
    }

    func mappedMessageRows(
        in chatGUID: String,
        cursor: String?,
        direction: MappedPageDirection?,
        limit: Int = 20
    ) throws -> [MappedMessageRow] {
        let messageSchema = try schema().message
        let withCursor = cursor.flatMap { Int($0) }.map { (cursor: $0, direction: direction ?? .before) }
        let comparisonOperator = withCursor.map { $0.direction == .after ? ">" : "<" }
        let order = withCursor?.direction == .after ? "ASC" : "DESC"
        let dateExpression = comparisonOperator == ">" && messageSchema.has(.dateEdited)
            ? "MAX(m.\(MessageTable.Column.date.sqlName), COALESCE(m.\(MessageTable.Column.dateEdited.sqlName), 0))"
            : "cmj.\(ChatMessageJoinTable.Column.messageDate.sqlName)"

        // The historical query filtered by chat guid after starting from
        // `message ORDER BY date`. On large databases that can walk a huge
        // date index to find a sparse chat. Starting from chat_message_join's
        // chat_id/date indexes touches only the requested chat's messages.
        guard let chatRowID = try mappedChatRowID(guid: chatGUID) else {
            return []
        }

        var sql = """
        SELECT
        \(messageSelectionSQL(messageSchema: messageSchema))
        FROM chat_message_join AS cmj
        \(messageJoinsFromChatMessageJoin)
        WHERE cmj.chat_id = ?
        """
        if let comparisonOperator {
            sql += "\nAND \(dateExpression) \(comparisonOperator) ?"
        }
        sql += "\nORDER BY cmj.message_date \(order), cmj.message_id \(order)\nLIMIT \(limit)"

        return try read { db in
            if let withCursor {
                return try MappedMessageRow.fetchAllMapped(db, sql: sql, arguments: sqlArguments([chatRowID, withCursor.cursor]))
            }
            return try MappedMessageRow.fetchAllMapped(db, sql: sql, arguments: [chatRowID])
        }
    }

    func mappedChatRowID(guid: String) throws -> Int? {
        try read { db in
            try fetchOneSQL(Int.self, db: db, sql: "SELECT ROWID FROM chat WHERE guid = ?", arguments: [guid])
        }
    }

    func mappedMessageRow(guid: String) throws -> MappedMessageRow? {
        try mappedMessageRows(guids: [guid]).first
    }

    func mappedMessageRows(guids: [String]) throws -> [MappedMessageRow] {
        guard !guids.isEmpty else { return [] }
        let uniqueGUIDs = Array(OrderedSet(guids))

        guard uniqueGUIDs.count <= maxMappedMessageRowsBatchSize else {
            return try uniqueGUIDs
                .chunks(ofCount: maxMappedMessageRowsBatchSize)
                .flatMap { try mappedMessageRows(guids: Array($0)) }
        }

        let messageSchema = try schema().message
        let sql = """
        SELECT
        \(messageSelectionSQL(messageSchema: messageSchema))
        FROM message AS m
        \(messageJoins)
        WHERE m.guid IN (\(placeholders(count: uniqueGUIDs.count)))
        """
        return try read { db in
            try MappedMessageRow.fetchAllMapped(db, sql: sql, arguments: uniqueGUIDs)
        }
    }

    func mappedMessageRows(rowIDs: [Int]) throws -> [MappedMessageRow] {
        guard !rowIDs.isEmpty else { return [] }
        let uniqueRowIDs = Array(OrderedSet(rowIDs))

        guard uniqueRowIDs.count <= maxMappedMessageRowsBatchSize else {
            return try uniqueRowIDs
                .chunks(ofCount: maxMappedMessageRowsBatchSize)
                .flatMap { try mappedMessageRows(rowIDs: Array($0)) }
                .sorted { ($0.date ?? 0) > ($1.date ?? 0) }
        }

        let messageSchema = try schema().message
        let sql = """
        SELECT
        \(messageSelectionSQL(messageSchema: messageSchema))
        FROM message AS m
        \(messageJoins)
        WHERE m.ROWID IN (\(placeholders(count: uniqueRowIDs.count)))
        ORDER BY m.date DESC
        """
        return try read { db in
            try MappedMessageRow.fetchAllMapped(db, sql: sql, arguments: uniqueRowIDs)
        }
    }

    func mappedLatestMessageRows(chatRowIDs: [Int]) throws -> [String: MappedMessageRow] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let messageSchema = try schema().message
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
        \(messageSelectionSQL(messageSchema: messageSchema))
        FROM latest_join
        \(latestMessageJoins)
        ORDER BY m.date DESC
        """
        return try read { db in
            try MappedMessageRow.fetchAllMapped(db, sql: sql, arguments: chatRowIDs).reduce(into: [:]) { result, messageRow in
                guard let threadID = messageRow.threadID else { return }
                result[threadID] = messageRow
            }
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
        return try read { db in
            try MappedAttachmentRow.fetchAllMapped(db, sql: sql, arguments: messageRowIDs)
        }
    }

    func attachmentFilename(guid: String) throws -> String? {
        try read { db in
            try fetchOneOptionalSQL(String.self, db: db, sql: "SELECT filename FROM attachment WHERE guid = ?", arguments: [guid])
        }
    }

    func attachmentFilename(messageRowID: Int) throws -> String? {
        try read { db in
            try fetchOneOptionalSQL(String.self, db: db, sql: """
            SELECT a.filename FROM message_attachment_join AS maj
            INNER JOIN attachment AS a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
            """, arguments: [messageRowID])
        }
    }

    func mappedReactionRows(messageGUIDs: [String], chatRowIDs: [Int]) throws -> [MappedReactionMessageRow] {
        guard !messageGUIDs.isEmpty, !chatRowIDs.isEmpty else { return [] }
        let messageSchema = try schema().message
        let emojiColumn = messageSchema.has(.associatedMessageEmoji)
            ? "m.\(MessageTable.Column.associatedMessageEmoji.sqlName) AS \(MessageTable.Column.associatedMessageEmoji.sqlName)"
            : "NULL AS \(MessageTable.Column.associatedMessageEmoji.sqlName)"
        let messageGUIDPlaceholders = messageGUIDs.map { _ in "?" }.joined(separator: ",")
        let chatRowIDPlaceholders = chatRowIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT m.ROWID, is_from_me, handle_id, associated_message_type, associated_message_guid, \(emojiColumn), h.id AS participantID
        FROM message AS m
        LEFT JOIN handle AS h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
        WHERE REPLACE(SUBSTR(associated_message_guid, INSTR(associated_message_guid, '/') + 1), 'bp:', '') IN (\(messageGUIDPlaceholders))
        AND cmj.chat_id IN (\(chatRowIDPlaceholders))
        ORDER BY m.ROWID ASC
        """
        return try read { db in
            let bindings = messageGUIDs.map { $0 as Any } + chatRowIDs.map { $0 as Any }
            return try MappedReactionMessageRow.fetchAllMapped(db, sql: sql, arguments: sqlArguments(bindings))
        }
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

private func messageSelectionSQL(messageSchema: TableSchema<MessageTable>) -> String {
    var selections = mappedMessageColumnNames.map {
        columnSelection($0, tableAlias: "m", tableColumns: messageSchema.columns)
    }
    selections += [
        "t.guid AS threadID",
        "t.ROWID AS chatRowID",
        "t.room_name",
        "h.id AS participantID",
        "oh.id AS otherID",
    ]
    return selections.joined(separator: ",\n")
}

private let mappedMessageColumnNames = [
    "ROWID",
    "guid",
    "text",
    "subject",
    "attributedBody",
    "service",
    "error",
    "date",
    "date_read",
    "date_delivered",
    "is_delivered",
    "is_from_me",
    "is_read",
    "is_audio_message",
    "item_type",
    "handle_id",
    "group_title",
    "group_action_type",
    "share_status",
    "associated_message_guid",
    "associated_message_type",
    "associated_message_emoji",
    "balloon_bundle_id",
    "payload_data",
    "expressive_send_style_id",
    "message_summary_info",
    "reply_to_guid",
    "thread_originator_guid",
    "thread_originator_part",
    "date_retracted",
    "date_edited",
    "was_detonated",
    "schedule_type",
]

private func columnSelection(_ column: String, tableAlias: String, tableColumns: [String]) -> String {
    if tableColumns.contains(column) {
        return "\(tableAlias).\(column) AS \(column)"
    }
    return "NULL AS \(column)"
}

private struct MessageUpdateCursorSnapshotRow: QueryRepresentable {
    typealias QueryOutput = Self

    let lastRowID: Int
    let lastDateRead: Date?
    let lastDateEdited: Date?

    init(decoder: inout some QueryDecoder) throws {
        lastRowID = try decoder.optionalInt() ?? 0
        lastDateRead = try decoder.imCoreDate()
        lastDateEdited = try decoder.imCoreDate()
    }
}

private struct SentMessageIDRow: QueryRepresentable {
    typealias QueryOutput = Self

    let rowID: Int
    let guid: String

    init(decoder: inout some QueryDecoder) throws {
        rowID = try decoder.requiredInt("ROWID", row: Self.self)
        guid = try decoder.requiredString("guid", row: Self.self)
    }
}

private func placeholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}

private func rowValuePlaceholders(count: Int) -> String {
    Array(repeating: "(?)", count: count).joined(separator: ", ")
}
