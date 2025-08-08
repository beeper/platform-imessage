import Foundation
import Logging

private let log = Logger(label: "imdb.updates")

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
            newestMessageRowID = try max(row[0].expect(Int.self), newestMessageRowID ?? 0)

            dateRead: do {
                // AFAICT this is a timestamp or zero. The column itself is
                // nullable but my local database doesn't have any `NULL`s, just
                // zeroes
                let nanoseconds = try row[1].optional(Int.self) ?? 0
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

            let rowID = try row[2].expect(Int.self)
            let guid = try row[3].optional(String.self)
            if guid == nil {
                log.error("chat \(rowID) has a `NULL` GUID for some reason, continuing with chat query")
            }
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
