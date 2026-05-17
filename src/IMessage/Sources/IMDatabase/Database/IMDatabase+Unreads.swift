import Foundation
import SQLite
import IMessageCore

private let reactionAssociatedMessageTypeLowerBound = 2000
private let reactionAssociatedMessageTypeUpperBound = 3007

public struct ChatState: Equatable {
    public var isUnread: Bool
    public var lastReadMessageTimestamp: Date

    public init(isUnread: Bool, lastReadMessageTimestamp: Date) {
        self.isUnread = isUnread
        self.lastReadMessageTimestamp = lastReadMessageTimestamp
    }

    @available(*, deprecated, message: "Use init(isUnread:lastReadMessageTimestamp:); ChatState no longer computes exact unread counts.")
    public init(unreadCount: Int, lastReadMessageTimestamp: Date) {
        self.init(isUnread: unreadCount > 0, lastReadMessageTimestamp: lastReadMessageTimestamp)
    }

    @available(*, deprecated, message: "Use isUnread; ChatState no longer computes exact unread counts.")
    public var unreadCount: Int {
        get { isUnread ? 1 : 0 }
        set { isUnread = newValue > 0 }
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
        let query = threadUnreadQuery(messageColumns: try tableColumns("message"))
        let statement = try cachedStatement(forEscapedSQL: query).reset()
        try statement.bind(chat.id)
        let isUnread = try statement.mapRowsUntilDone { row in
            try row[0].expectConverting(Int.self) != 0
        }.first ?? false
        return !isUnread
    }

    func chatStates() throws -> [String: ChatState] {
        let query = unreadStatesQuery(messageColumns: try tableColumns("message"))
        let statement = try cachedStatement(forEscapedSQL: query).reset()

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

private func unreadStatesQuery(messageColumns: [String]) -> String {
    """
    SELECT
        c.guid AS chat_guid,
        \(latestRelevantIncomingUnreadSQL(chatIDExpression: "c.ROWID", messageColumns: messageColumns)) AS is_unread,
        c.last_read_message_timestamp
    FROM
        chat c
    WHERE EXISTS (
        SELECT 1
        FROM chat_message_join cm
        WHERE cm.chat_id = c.ROWID
    )
    """
}

private func threadUnreadQuery(messageColumns: [String]) -> String {
    """
    SELECT
        \(latestRelevantIncomingUnreadSQL(chatIDExpression: "?", messageColumns: messageColumns)) AS is_unread
    """
}

private func latestRelevantIncomingUnreadSQL(chatIDExpression: String, messageColumns: [String]) -> String {
    """
    COALESCE((
            SELECT m.is_read = 0
            FROM chat_message_join cm
            INNER JOIN message m ON m.ROWID = cm.message_id
            WHERE cm.chat_id = \(chatIDExpression)
                AND \(latestRelevantIncomingMessageWhereClause(messageColumns: messageColumns))
            ORDER BY cm.message_date DESC, cm.message_id DESC
            LIMIT 1
        ), 0)
    """
}

private func latestRelevantIncomingMessageWhereClause(messageColumns: [String]) -> String {
    var filters = [
        "m.is_from_me = 0",
        "m.item_type = 0",
    ]
    if messageColumns.contains("associated_message_type") {
        filters.append("""
        (
            m.associated_message_type IS NULL
            OR m.associated_message_type NOT BETWEEN \(reactionAssociatedMessageTypeLowerBound) AND \(reactionAssociatedMessageTypeUpperBound)
        )
        """)
    }
    if messageColumns.contains("schedule_type") {
        filters.append("COALESCE(m.schedule_type, 0) = 0")
    }
    if messageColumns.contains("date_retracted") {
        filters.append("COALESCE(m.date_retracted, 0) = 0")
    }
    if messageColumns.contains("was_detonated") {
        filters.append("COALESCE(m.was_detonated, 0) = 0")
    }
    return filters.joined(separator: "\n                AND ")
}
