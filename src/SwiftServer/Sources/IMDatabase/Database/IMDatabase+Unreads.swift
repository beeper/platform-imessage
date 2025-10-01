import Foundation
import Logging
import SQLite

private let log = Logger(label: "imdb.unreads")

// TODO(skip): optimize; query takes ~70ms (!)
let unreadStatesQuery = """
SELECT
    c.ROWID AS chat_id,
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
"""

public struct UnreadState: Equatable {
    public var unreadCount: Int
    public var lastReadMessageTimestamp: Date
}

extension UnreadState: CustomStringConvertible {
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
    typealias UnreadStates = [ChatRef: UnreadState]

    func queryUnreadStates() throws -> UnreadStates {
        let statement = try cachedStatement(forEscapedSQL: unreadStatesQuery)
        try statement.reset()

        var unreadStates = UnreadStates()
        try statement.stepUntilDone { row in
            let chat = try ChatRef(rowID: row[0].optional(Int.self), guid: row[1].optional(String.self))
            guard let chat else {
                log.warning("while querying unread states: some chat had neither a rowid nor a guid. can't really do much with this")
                return
            }
            let lastReadMessageTimestamp = try Date(nanosecondsSinceReferenceDate: row[3].expect(Int.self))
            let unreadCount = try row[2].expect(Int.self)
            unreadStates[chat] = UnreadState(unreadCount: unreadCount, lastReadMessageTimestamp: lastReadMessageTimestamp)
        }
        return unreadStates
    }
}
