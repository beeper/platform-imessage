import Foundation
import IMessageCore

public struct ChatState: Equatable {
    public var isUnread: Bool
    public var lastReadMessageTimestamp: Date

    public init(isUnread: Bool, lastReadMessageTimestamp: Date) {
        self.isUnread = isUnread
        self.lastReadMessageTimestamp = lastReadMessageTimestamp
    }
}

extension ChatState: CustomStringConvertible {
    public var description: String {
        let unreadDescription = isUnread ? "unread" : "read"
        return "[\(unreadDescription), last read: \(lastReadMessageTimestamp)]"
    }
}

public extension IMDatabase {
    func isThreadRead(chatGUID: String) throws -> Bool {
        let chat = try chat(withGUID: chatGUID).orThrow(ErrorMessage("expected chat \(chatGUID) to exist"))
        let statement = try cachedStatement(forEscapedSQL: threadUnreadQuery).reset()
        try statement.bind(chat.id)
        let isUnread = try statement.mapRowsUntilDone { row in
            try row[0].expectConverting(Int.self) != 0
        }.first ?? false
        return !isUnread
    }

    func chatStates() throws -> [String: ChatState] {
        let statement = try cachedStatement(forEscapedSQL: unreadStatesQuery).reset()

        var chatStates: [String: ChatState] = [:]

        try statement.stepUntilDone { row in
            let chatGUID = try row[0].expect(String.self)

            let lastReadMessageTimestamp = try Date(nanosecondsSinceReferenceDate: row[2].expect(Int.self))

            let isUnread = try row[1].expectConverting(Int.self) != 0

            chatStates[chatGUID] = ChatState(isUnread: isUnread, lastReadMessageTimestamp: lastReadMessageTimestamp)
        }

        return chatStates
    }
}

private let unreadStatesQuery = """
    SELECT
        c.guid AS chat_guid,
        \(latestMessageUnreadExpression(chatIDExpression: "c.ROWID")) AS is_unread,
        c.last_read_message_timestamp
    FROM
        chat c
    WHERE EXISTS (
        SELECT 1
        FROM chat_message_join cm
        WHERE cm.chat_id = c.ROWID
    )
    """

private let threadUnreadQuery = """
    SELECT
        \(latestMessageUnreadExpression(chatIDExpression: "?")) AS is_unread
    """

private func latestMessageUnreadExpression(chatIDExpression: String) -> String {
    // Apple uses `is_finished = 1` and `is_system_message = 0` in newer unread
    // indexes, but this repo has no macOS 11 fixture proving those columns.
    // Keep this to the legacy `is_read`/`is_from_me`/`item_type` predicate until Big Sur is verified.
    """
    COALESCE((
            SELECT m.is_read = 0
            FROM chat_message_join cm
            INNER JOIN message m ON m.ROWID = cm.message_id
            WHERE cm.chat_id = \(chatIDExpression)
              AND m.is_from_me = 0
              AND m.item_type = 0
            ORDER BY cm.message_date DESC, cm.message_id DESC
            LIMIT 1
        ), 0)
    """
}
