import Foundation
import Logging

private let log = Logger(label: "imdb.updates")

private let updatedMessagesSinceQuery = """
WITH updated(rowid) AS (
    SELECT ROWID
    FROM message
    WHERE ROWID > ?
    UNION
    SELECT ROWID
    FROM message
    WHERE date_read > ?
    UNION
    SELECT ROWID
    FROM message
    WHERE date_edited > ?
)
SELECT
    m.ROWID,
    m.date_read,
    m.date_edited,
    c.guid
FROM
    updated u
CROSS JOIN
    message m
LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat c ON cmj.chat_id = c.ROWID
WHERE
    m.ROWID = u.rowid
ORDER BY
    m.ROWID ASC
"""

package struct UpdatedMessageChange {
    package let rowID: Int
    package let chatGUID: String
    package let isNew: Bool
    package let wasRead: Bool
    package let wasEdited: Bool

    package init(rowID: Int, chatGUID: String, isNew: Bool, wasRead: Bool, wasEdited: Bool) {
        self.rowID = rowID
        self.chatGUID = chatGUID
        self.isNew = isNew
        self.wasRead = wasRead
        self.wasEdited = wasEdited
    }
}

package struct UpdatedMessagesQueryResult {
    package let updatedMessages: [UpdatedMessageChange]
    package let nextCursor: MessageUpdatesCursor
}

extension IMDatabase {
    package
    func messages(since cursor: MessageUpdatesCursor) throws -> UpdatedMessagesQueryResult {
        let statement = try cachedStatement(forEscapedSQL: updatedMessagesSinceQuery)

        try statement.reset()
        try statement.bind(
            cursor.lastRowID,
            cursor.lastDateRead.nanosecondsSinceReferenceDate,
            cursor.lastDateEdited.nanosecondsSinceReferenceDate
        )

        var nextLastRowID = cursor.lastRowID
        var nextLastDateRead = cursor.lastDateRead
        var nextLastDateEdited = cursor.lastDateEdited
        var timesWarnedAboutOrphanedMessage = 0

        let updatedMessages: [UpdatedMessageChange] = try statement.compactMapRowsUntilDone { row in
            let messageRowID = try row[0].expect(Int.self)
            let isNew = messageRowID > cursor.lastRowID
            if isNew {
                nextLastRowID = max(messageRowID, nextLastRowID)
            }

            var wasRead = false
            var wasEdited = false

            if let dateRead = try row[1].imCoreDate() {
                wasRead = dateRead > cursor.lastDateRead
                if wasRead {
                    nextLastDateRead = max(dateRead, nextLastDateRead)
                }
            }

            if let dateEdited = try row[2].imCoreDate() {
                wasEdited = dateEdited > cursor.lastDateEdited
                if wasEdited {
                    nextLastDateEdited = max(dateEdited, nextLastDateEdited)
                }
            }

            guard let guid = try row[3].optional(String.self) else {
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
                chatGUID: guid,
                isNew: isNew,
                wasRead: wasRead,
                wasEdited: wasEdited
            )
        }

        return UpdatedMessagesQueryResult(
            updatedMessages: updatedMessages,
            nextCursor: MessageUpdatesCursor(
                lastRowID: nextLastRowID,
                lastDateRead: nextLastDateRead,
                lastDateEdited: nextLastDateEdited
            )
        )
    }
}
