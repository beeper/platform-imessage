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
        var timesWarnedAboutOrphanedMessage = 0

        let updatedChats: [ChatRef] = try statement.compactMapRowsUntilDone { row in
            let messageRowID = try row[0].expect(Int.self)
            newestMessageRowID = max(messageRowID, newestMessageRowID ?? 0)

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

            guard let rowID = try row[2].optional(Int.self), let guid = try row[3].optional(String.self) else {
                // For whatever reason it's possible for messages to not be
                // joinable with chats. Right now I have one of these for a SMS
                // TOTP verification code, which might've been automatically
                // deleted in a weird way due to the autofill feature.
                //
                // In case there are tons of orphaned messages, don't spam the
                // logs with this message.
                if timesWarnedAboutOrphanedMessage < 10 {
                    log.error("couldn't join message \(messageRowID) to chat, dropping")
                    timesWarnedAboutOrphanedMessage += 1
                }
                return nil
            }

            return ChatRef(rowID: rowID, guid: guid)
        }

        return UpdatedChatsQueryResult(
            updatedChats: updatedChats,
            latestMessageRowID: newestMessageRowID,
            latestMessageDateRead: latestMessageDateRead
        )
    }
}
