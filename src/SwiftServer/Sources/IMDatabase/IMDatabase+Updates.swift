import Foundation

let updatedChatsSinceQuery = """
SELECT
    m.ROWID,
    m.date_read,
    c.guid
FROM
    message AS m
    LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
    LEFT JOIN chat c ON cmj.chat_id = c.ROWID
WHERE
    m.ROWID > ?
    OR m.date_read > ?
GROUP BY
    c.guid
ORDER BY
    date DESC
"""

public typealias ChatGUID = String

public struct UpdatedChatsQueryResult {
    public var updatedChatGUIDs: [ChatGUID]
    public var overallNewestMessageRowID: Int?
    public var overallLatestMessageDateRead: Date?
}

public extension IMDatabase {
    func queryChats(withMessagesWithRowIDsNewerThan lastRowID: Int, orReadSince lastDateRead: Date) throws -> UpdatedChatsQueryResult {
        let statement = try cachedStatement(&messageUpdatesStatement, creatingWithoutEscapingSQL: updatedChatsSinceQuery)

        try statement.reset()
        try statement.bind(lastRowID, lastDateRead.nanosecondsSinceReferenceDate)

        var newestMessageRowID: Int?
        var latestMessageDateRead: Date?
        let updatedChatGUIDs = try statement.mapRowsUntilDone { row in
            newestMessageRowID = max(row[0].as(Int.self), newestMessageRowID ?? 0)
            latestMessageDateRead = max(Date(nanosecondsSinceReferenceDate: row[1].as(Int.self)), latestMessageDateRead ?? .distantPast)
            return row[2].as(String.self)
        }

        return UpdatedChatsQueryResult(
            updatedChatGUIDs: updatedChatGUIDs,
            overallNewestMessageRowID: newestMessageRowID,
            overallLatestMessageDateRead: latestMessageDateRead
        )
    }
}

private extension Date {
    var nanosecondsSinceReferenceDate: Int {
        Int(timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    init(nanosecondsSinceReferenceDate nanos: Int) {
        self = Date(timeIntervalSinceReferenceDate: Double(nanos) / 1_000_000_000)
    }
}
