import Logging
import Foundation
import SQLite

private let log = Logger(label: "imdb.unreads")

// TODO(skip): optimize; query takes ~70ms (!)
let unreadStatesQuery = """
SELECT
    c.ROWID AS chat_id,
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

    init(row: borrowing Row) {
        unreadCount = row[1].as(Int.self)
        let secondsSinceAppleEpoch = row[2].as(Double.self) / 1_000_000_000.0
        lastReadMessageTimestamp = Date(timeIntervalSinceReferenceDate: secondsSinceAppleEpoch)
    }
}

public extension IMDatabase {
    typealias UnreadStates = [Int: UnreadState]

    func queryUnreadStates() throws -> UnreadStates {
        let statement = try unreadStatesStatement ?? {
            let statement = try database.prepare(sqlWithoutEscaping: unreadStatesQuery, flags: .persistent)
            unreadStatesStatement = statement
            return statement
        }()

        try statement.reset()

        var unreadStates = UnreadStates()
        try statement.stepUntilDone { row in
            unreadStates[row[0].as(Int.self)] = UnreadState(row: row)
        }
        return unreadStates
    }
}
