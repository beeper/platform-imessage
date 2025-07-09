import Foundation

let updatedChatsSinceQuery = """
SELECT
    m.ROWID,
    m.date_read,
    c.ROWID,
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

public struct UpdatedChatsQueryResult {
    public var updatedChats: [ChatRef]
    /// This maximum is local to the set of updated chats.
    public var latestMessageRowID: Int?
    /// This maximum is local to the set of updated chats.
    public var latestMessageDateRead: Date?
}

public extension IMDatabase {
    func chats(withMessagesNewerThanRowID lastRowID: Int, orReadSince lastDateRead: Date) throws -> UpdatedChatsQueryResult {
        let statement = try cachedStatement(&messageUpdatesStatement, creatingWithoutEscapingSQL: updatedChatsSinceQuery)

        try statement.reset()
        try statement.bind(lastRowID, lastDateRead.nanosecondsSinceReferenceDate)

        var newestMessageRowID: Int?
        var latestMessageDateRead: Date?
        let updatedChats = try statement.mapRowsUntilDone { row in
            newestMessageRowID = max(row[0].as(Int.self), newestMessageRowID ?? 0)

            dateRead: do {
                let nanoseconds = row[1].as(Int.self)
                // If the message hasn't been read yet (we get `0`), then don't
                // update the "latest read date" at all.
                guard nanoseconds > 0 else { break dateRead }

                let dateRead = Date(nanosecondsSinceReferenceDate: nanoseconds)
                latestMessageDateRead = if let latestMessageDateRead {
                    max(dateRead, latestMessageDateRead)
                } else {
                    dateRead
                }
            }

            let rowID = row[2].as(Int.self)
            let guid = row[3].as(String.self)
            return ChatRef(rowID: rowID, guid: guid)
        }

        return UpdatedChatsQueryResult(
            // Discard chats without a `guid` and `ROWID` (impossible?)
            updatedChats: updatedChats.compactMap(\.self),
            latestMessageRowID: newestMessageRowID,
            latestMessageDateRead: latestMessageDateRead
        )
    }
}
