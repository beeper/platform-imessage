import Foundation
import GRDB
import IMessageCore

// TODO(skip): optimize; query takes ~70ms (!)
let unreadStatesQuery = """
SELECT
    c.guid AS chat_guid,
    COUNT(
        CASE
            WHEN m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0
            THEN 1
            ELSE NULL
        END
    ) AS unread_count,
    c.last_read_message_timestamp
FROM
    chat c
LEFT JOIN
    chat_message_join cm ON c.ROWID = cm.chat_id
LEFT JOIN
    message m ON m.ROWID = cm.message_id
GROUP BY
    c.ROWID
HAVING
    COUNT(cm.message_id) > 0
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

    func chatStates() throws -> [String: ChatState] {
        var chatStates: [String: ChatState] = [:]

        try read { db in
            for row in try Row.fetchAll(db, sql: unreadStatesQuery) {
                let chatGUID = row.requiredString(at: 0)

                let lastReadMessageTimestamp = Date(nanosecondsSinceReferenceDate: row.requiredInt(at: 2))

                let unreadCount = row.requiredInt(at: 1)

                chatStates[chatGUID] = ChatState(unreadCount: unreadCount, lastReadMessageTimestamp: lastReadMessageTimestamp)
            }
        }

        return chatStates
    }
}
