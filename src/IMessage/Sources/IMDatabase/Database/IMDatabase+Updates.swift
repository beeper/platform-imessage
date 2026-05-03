import Foundation
import Logging

private let log = Logger(label: "imdb.updates")

let updatedMessagesSinceQuery = """
SELECT
    m.ROWID,
    m.date_read,
    m.date_edited,
    c.ROWID,
    c.guid
FROM
    message m
LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat c ON cmj.chat_id = c.ROWID
WHERE
    m.ROWID > ? OR m.date_read > ? OR m.date_edited > ?
ORDER BY
    m.ROWID ASC
"""

package struct UpdatedMessageChange {
    package var rowID: Int
    package var chat: ChatRef
    package var isNew: Bool
    package var wasRead: Bool
    package var wasEdited: Bool
}

package struct UpdatedMessagesQueryResult {
    package var updatedMessages: [UpdatedMessageChange]
    /// This maximum is local to the set of newly inserted message rows.
    package var latestMessageRowID: Int?
    /// This maximum is local to the set of read updates.
    package var latestMessageDateRead: Date?
    /// This maximum is local to the set of edit updates.
    package var latestDateEdited: Date?
}

extension IMDatabase {
    package
    func messages(newerThanRowID lastRowID: Int, orReadSince lastDateRead: Date, orEditedSince lastDateEdited: Date) throws -> UpdatedMessagesQueryResult {
        let statement = try cachedStatement(forEscapedSQL: updatedMessagesSinceQuery)

        try statement.reset()
        try statement.bind(lastRowID, lastDateRead.nanosecondsSinceReferenceDate, lastDateEdited.nanosecondsSinceReferenceDate)

        var newestMessageRowID: Int?
        var latestMessageDateRead: Date?
        var latestDateEdited: Date?
        var timesWarnedAboutOrphanedMessage = 0

        let updatedMessages: [UpdatedMessageChange] = try statement.compactMapRowsUntilDone { row in
            let messageRowID = try row[0].expect(Int.self)
            let isNew = messageRowID > lastRowID
            if isNew {
                newestMessageRowID = max(messageRowID, newestMessageRowID ?? 0)
            }

            var wasRead = false
            var wasEdited = false

            if let dateRead = try row[1].imCoreDate() {
                wasRead = dateRead > lastDateRead
                if wasRead {
                    latestMessageDateRead = if let latestMessageDateRead {
                        max(dateRead, latestMessageDateRead)
                    } else {
                        dateRead
                    }
                }
            }

            if let dateEdited = try row[2].imCoreDate() {
                wasEdited = dateEdited > lastDateEdited
                if wasEdited {
                    latestDateEdited = if let latestDateEdited {
                        max(dateEdited, latestDateEdited)
                    } else {
                        dateEdited
                    }
                }
            }

            guard let rowID = try row[3].optional(Int.self), let guid = try row[4].optional(String.self) else {
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

            return UpdatedMessageChange(
                rowID: messageRowID,
                chat: .both(rowID: rowID, guid: guid),
                isNew: isNew,
                wasRead: wasRead,
                wasEdited: wasEdited
            )
        }

        return UpdatedMessagesQueryResult(
            updatedMessages: updatedMessages,
            latestMessageRowID: newestMessageRowID,
            latestMessageDateRead: latestMessageDateRead,
            latestDateEdited: latestDateEdited
        )
    }
}
