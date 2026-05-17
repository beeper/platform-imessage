import Foundation
import SQLite
import IMessageCore

public struct ChatState: Equatable {
    public var unreadCount: Int
    public var lastReadMessageTimestamp: Date
}

extension ChatState: CustomStringConvertible {
    public var description: String {
        let unreadDescription = if unreadCount == 0 {
            "read"
        } else if unreadCount == 1 {
            "1 unread"
        } else {
            "\(unreadCount) unreads"
        }
        return "[\(unreadDescription), last read: \(lastReadMessageTimestamp)]"
    }
}

public extension IMDatabase {
    func isThreadRead(chatGUID: String) throws -> Bool {
        let chat = try chat(withGUID: chatGUID).orThrow(ErrorMessage("expected chat \(chatGUID) to exist"))
        let unreadCounts = try mappedUnreadCounts(chatRowIDs: [chat.id])
        return (unreadCounts[chat.id] ?? 0) == 0
    }

    func chatStates() throws -> [String: ChatState] {
        let statement = try cachedStatement(forEscapedSQL: chatStatesSQL())
        try statement.reset()
        return try mappedChatStates(statement: statement)
    }

    func chatStates(forChatGUIDs chatGUIDs: [String]) throws -> [String: ChatState] {
        let chatGUIDs = Array(Set(chatGUIDs))
        guard !chatGUIDs.isEmpty else { return [:] }

        let statement = try cachedStatement(forEscapedSQL: chatStatesSQL(filteringToGUIDCount: chatGUIDs.count))
        try statement.reset()
        try statement.bind(chatGUIDs.map { $0 as any SQLiteBindable })
        return try mappedChatStates(statement: statement)
    }

    func chatGUIDsWithMessages() throws -> Set<String> {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT c.guid
        FROM chat c
        WHERE EXISTS (
            SELECT 1
            FROM chat_message_join cm
            WHERE cm.chat_id = c.ROWID
                AND cm.message_id IS NOT NULL
            LIMIT 1
        )
        """)
        try statement.reset()

        return try Set(statement.mapRowsUntilDone { row in
            try row[0].expect(String.self)
        })
    }
}

private extension IMDatabase {
    func chatStatesSQL(filteringToGUIDCount chatGUIDCount: Int? = nil) -> String {
        let chatGUIDFilter = chatGUIDCount.map {
            "AND c.guid IN (\(Array(repeating: "?", count: $0).joined(separator: ", ")))"
        } ?? ""
        let unreadChatIDFilter = if chatGUIDCount == nil {
            ""
        } else {
            "AND cm.chat_id IN (SELECT ROWID FROM chat_rows)"
        }

        return """
        WITH chat_rows AS (
            SELECT c.ROWID, c.guid, c.last_read_message_timestamp
            FROM chat c
            WHERE EXISTS (
                SELECT 1
                FROM chat_message_join cm
                WHERE cm.chat_id = c.ROWID
                    AND cm.message_id IS NOT NULL
                LIMIT 1
            )
            \(chatGUIDFilter)
        ),
        unread_counts AS (
            SELECT
                cm.chat_id AS chat_id,
                COUNT(cm.chat_id) AS unread_count
            FROM
                (
                    SELECT ROWID AS message_id
                    FROM message
                    WHERE item_type = 0
                        AND is_read = 0
                        AND is_from_me = 0
                ) unread
            JOIN
                chat_message_join cm ON
                    cm.message_id = unread.message_id
                    \(unreadChatIDFilter)
            GROUP BY
                cm.chat_id
        )
        SELECT
            chat_rows.guid AS chat_guid,
            COALESCE(unread_counts.unread_count, 0) AS unread_count,
            chat_rows.last_read_message_timestamp
        FROM
            chat_rows
        LEFT JOIN
            unread_counts ON unread_counts.chat_id = chat_rows.ROWID
        """
    }

    func mappedChatStates(statement: Statement) throws -> [String: ChatState] {
        try statement.mapRowsUntilDone { row in
            (
                try row[0].expect(String.self),
                ChatState(
                    unreadCount: try row[1].expectConverting(Int.self),
                    lastReadMessageTimestamp: Date(nanosecondsSinceReferenceDate: try row[2].expect(Int.self))
                )
            )
        }.reduce(into: [:]) { result, pair in
            result[pair.0] = pair.1
        }
    }
}
