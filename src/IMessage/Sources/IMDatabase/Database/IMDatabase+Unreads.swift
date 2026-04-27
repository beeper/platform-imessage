import Foundation
import Logging
import SQLite
import IMessageCore

private let log = Logger(label: "imdb.unreads")

let unreadStatesQuery = """
WITH chats_with_messages AS (
    SELECT chat_id
    FROM chat_message_join
    GROUP BY chat_id
),
unread_counts AS (
    SELECT
        cm.chat_id AS chat_id,
        COUNT(*) AS unread_count
    FROM
        message m
    INNER JOIN
        chat_message_join cm ON m.ROWID = cm.message_id
    WHERE
        m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0
    GROUP BY
        cm.chat_id
)
SELECT
    c.ROWID AS chat_id,
    c.guid AS chat_guid,
    COALESCE(unread_counts.unread_count, 0) AS unread_count,
    c.last_read_message_timestamp
FROM
    chats_with_messages
INNER JOIN
    chat c ON c.ROWID = chats_with_messages.chat_id
LEFT JOIN
    unread_counts ON unread_counts.chat_id = c.ROWID
"""

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

    func chatStates() throws -> [ChatRef: ChatState] {
        let statement = try cachedStatement(forEscapedSQL: unreadStatesQuery)
        try statement.reset()

        var chatStates: [ChatRef: ChatState] = [:]

        try statement.stepUntilDone { row in
            guard let chatRef: ChatRef = try ChatRef(rowID: row[0].optional(Int.self), guid: row[1].optional(String.self)) else {
                log.warning("while querying unread states: some chat had neither a rowid nor a guid. can't really do much with this")
                return
            }

            let lastReadMessageTimestamp = try Date(nanosecondsSinceReferenceDate: row[3].expect(Int.self))

            let unreadCount: Int = try row[2].expect(Int.self)

            chatStates[chatRef] = ChatState(unreadCount: unreadCount, lastReadMessageTimestamp: lastReadMessageTimestamp)
        }

        return chatStates
    }
}
