import Collections
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

// chat_message_join has no date-only index before macOS 26.3, so across all
// chats walk message's date index; CROSS JOIN pins that join order.
private let messageJoinsFromMessageByDate = """
FROM message AS m
CROSS JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
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

    func messageUpdateCursorSnapshot() throws -> MessageUpdatesCursor {
        let maxDateEdited = try tableColumns("message").contains("date_edited")
            ? "COALESCE((SELECT MAX(date_edited) FROM message), 0)"
            : "0"
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT
            COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'message'), 0),
            COALESCE((SELECT MAX(date_read) FROM message), 0),
            \(maxDateEdited)
        """).reset()

        return try statement.mapRowsUntilDone { row in
            MessageUpdatesCursor(
                lastRowID: try row[0].optionalConverting(Int.self) ?? 0,
                lastDateReadNanoseconds: try row[1].imCoreDateNanoseconds() ?? 0,
                lastDateEditedNanoseconds: try row[2].imCoreDateNanoseconds() ?? 0
            )
        }.first ?? .empty
    }

    func sentMessageIDs(since rowID: Int, reactionsOnly: Bool = false) throws -> [(rowID: Int, guid: String)] {
        let messageTypeClause = reactionsOnly ? """
        AND associated_message_type BETWEEN \(reactionAssociatedMessageTypeLowerBound) AND \(reactionAssociatedMessageTypeUpperBound)
        """ : """
        AND (associated_message_type IS NULL OR associated_message_type = 0)
        """
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT ROWID, guid
        FROM message
        WHERE is_from_me = 1 AND ROWID > ?
        \(messageTypeClause)
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

    func mappedLatestVisibleMessageRow(in chatGUID: String? = nil, offset: Int, ownedOnly: Bool = false) throws -> MappedMessageRow? {
        let chatRowID = try chatGUID.flatMap { try mappedChatRowID(guid: $0) }
        if chatGUID != nil, chatRowID == nil {
            return nil
        }

        let messageColumns = try tableColumns("message")
        var whereClauses = [String]()
        if chatRowID != nil {
            whereClauses.append("cmj.chat_id = ?")
        }
        if ownedOnly {
            whereClauses.append("m.is_from_me = 1")
        }
        let reactionClause = "m.associated_message_type NOT BETWEEN \(reactionAssociatedMessageTypeLowerBound) AND \(reactionAssociatedMessageTypeUpperBound)"
        whereClauses.append("(m.associated_message_type IS NULL OR \(reactionClause))")
        if messageColumns.contains("schedule_type") {
            whereClauses.append("COALESCE(m.schedule_type, 0) = 0")
        }
        if messageColumns.contains("date_retracted") {
            whereClauses.append("COALESCE(m.date_retracted, 0) = 0")
        }
        if messageColumns.contains("was_detonated") {
            whereClauses.append("COALESCE(m.was_detonated, 0) = 0")
        }
        let scoped = chatRowID != nil
        let sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        \(scoped ? "FROM chat_message_join AS cmj\n\(messageJoinsFromChatMessageJoin)" : messageJoinsFromMessageByDate)
        WHERE \(whereClauses.joined(separator: " AND "))
        ORDER BY \(scoped ? "cmj.message_date DESC, cmj.message_id DESC" : "m.date DESC, m.ROWID DESC")
        LIMIT 1 OFFSET ?
        """
        let statement = try cachedStatement(forEscapedSQL: sql).reset()
        if let chatRowID {
            try statement.bind(chatRowID, offset)
        } else {
            try statement.bind(offset)
        }
        return try statement.mapRowsUntilDone(MappedMessageRow.self).first
    }

    func mappedMessageRows(guids: [String]) throws -> [MappedMessageRow] {
        guard !guids.isEmpty else { return [] }
        let uniqueGUIDs = Array(OrderedSet(guids))

        guard uniqueGUIDs.count <= maxMappedMessageRowsBatchSize else {
            return try uniqueGUIDs
                .chunks(ofCount: maxMappedMessageRowsBatchSize)
                .flatMap { try mappedMessageRows(guids: Array($0)) }
        }

        let messageColumns = try tableColumns("message")
        let sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM message AS m
        \(messageJoins)
        WHERE m.guid IN (\(placeholders(count: uniqueGUIDs.count)))
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(uniqueGUIDs.map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone(MappedMessageRow.self)
    }

    func existingMessageGUIDs(among guids: [String]) throws -> Set<String> {
        guard !guids.isEmpty else { return [] }
        let uniqueGUIDs = Array(OrderedSet(guids))

        guard uniqueGUIDs.count <= maxMappedMessageRowsBatchSize else {
            return try uniqueGUIDs
                .chunks(ofCount: maxMappedMessageRowsBatchSize)
                .reduce(into: Set<String>()) { result, chunk in
                    try result.formUnion(existingMessageGUIDs(among: Array(chunk)))
                }
        }

        let sql = """
        SELECT guid
        FROM message
        WHERE guid IN (\(placeholders(count: uniqueGUIDs.count)))
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(uniqueGUIDs.map { $0 as any SQLiteBindable })
        return Set(try statement.compactMapRowsUntilDone { row in
            try row[0].optionalConverting(String.self)
        })
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

        let messageColumns = try tableColumns("message")
        let sql = """
        SELECT
        \(messageSelectionSQL(messageColumns: messageColumns))
        FROM message AS m
        \(messageJoins)
        WHERE m.ROWID IN (\(placeholders(count: uniqueRowIDs.count)))
        ORDER BY m.date DESC
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try statement.bind(uniqueRowIDs.map { $0 as any SQLiteBindable })
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
        // No index can match the associated GUID, so only scan each chat from
        // its oldest target onwards (less a day of clock skew); CROSS JOIN pins
        // the GUID lookup as the outer loop.
        let sql = """
        WITH target(chat_id, min_date) AS (
          SELECT tj.chat_id, MIN(tj.message_date)
          FROM message AS t
          CROSS JOIN chat_message_join AS tj
          WHERE tj.message_id = t.ROWID
          AND t.guid IN (\(messageGUIDPlaceholders))
          AND tj.chat_id IN (\(chatRowIDPlaceholders))
          GROUP BY tj.chat_id
        )
        SELECT m.ROWID, is_from_me, handle_id, associated_message_type, associated_message_guid, \(emojiColumn) h.id AS participantID
        FROM target
        INNER JOIN chat_message_join AS cmj ON cmj.chat_id = target.chat_id AND cmj.message_date >= target.min_date - \(reactionClockSkewNanoseconds)
        INNER JOIN message AS m ON m.ROWID = cmj.message_id
        LEFT JOIN handle AS h ON m.handle_id = h.ROWID
        WHERE REPLACE(SUBSTR(associated_message_guid, INSTR(associated_message_guid, '/') + 1), 'bp:', '') IN (\(messageGUIDPlaceholders))
        ORDER BY m.ROWID ASC
        """
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        var bindings = messageGUIDs.map { $0 as any SQLiteBindable }
        bindings.append(contentsOf: chatRowIDs.map { $0 as any SQLiteBindable })
        bindings.append(contentsOf: messageGUIDs.map { $0 as any SQLiteBindable })
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
// Associated message types 2000...3007 are tapback/reaction add/remove rows.
// The API exposes those as reactions plus hidden action messages, so `latest`
// aliases should skip them and resolve to the newest user-visible row.
private let reactionAssociatedMessageTypeLowerBound = 2000
private let reactionAssociatedMessageTypeUpperBound = 3007
private let reactionClockSkewNanoseconds = 86_400_000_000_000

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
