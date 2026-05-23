import Foundation
import Logging

private let log = Logger(label: "imdb.updates")

private let updatedMessagesSinceQuery = """
SELECT
    m.ROWID,
    m.date_read,
    m.date_edited,
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
    package let rowID: Int
    package let chatGUID: String
    package let isNew: Bool
    package let wasRead: Bool
    package let wasEdited: Bool
    package let isPreviewUpdate: Bool

    package init(
        rowID: Int,
        chatGUID: String,
        isNew: Bool,
        wasRead: Bool,
        wasEdited: Bool,
        isPreviewUpdate: Bool = false
    ) {
        self.rowID = rowID
        self.chatGUID = chatGUID
        self.isNew = isNew
        self.wasRead = wasRead
        self.wasEdited = wasEdited
        self.isPreviewUpdate = isPreviewUpdate
    }

    package func merging(_ other: UpdatedMessageChange) -> UpdatedMessageChange {
        UpdatedMessageChange(
            rowID: rowID,
            chatGUID: chatGUID,
            isNew: isNew || other.isNew,
            wasRead: wasRead || other.wasRead,
            wasEdited: wasEdited || other.wasEdited,
            isPreviewUpdate: isPreviewUpdate || other.isPreviewUpdate
        )
    }
}

package struct UpdatedMessagesQueryResult {
    package let updatedMessages: [UpdatedMessageChange]
    package let unresolvedNewMessageRowIDs: [Int]
    package let nextCursor: MessageUpdatesCursor

    package init(
        updatedMessages: [UpdatedMessageChange],
        unresolvedNewMessageRowIDs: [Int] = [],
        nextCursor: MessageUpdatesCursor
    ) {
        self.updatedMessages = updatedMessages
        self.unresolvedNewMessageRowIDs = unresolvedNewMessageRowIDs
        self.nextCursor = nextCursor
    }
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

        let rows = try statement.mapRowsUntilDone { row in
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

            return (
                rowID: messageRowID,
                chatGUID: try row[3].optional(String.self),
                isNew: isNew,
                wasRead: wasRead,
                wasEdited: wasEdited
            )
        }

        var updatedMessages: [UpdatedMessageChange] = []
        var unresolvedNewMessageRowIDs: [Int] = []
        var timesWarnedAboutOrphanedMessage = 0
        updatedMessages.reserveCapacity(rows.count)
        for row in rows {
            guard let guid = row.chatGUID else {
                // For whatever reason it's possible for messages to not be
                // joinable with chats. Right now I have one of these for a SMS
                // TOTP verification code, which might've been automatically
                // deleted in a weird way due to the autofill feature.
                //
                // New message rows can also briefly appear before their
                // chat_message_join row is visible to our connection. Return
                // those row IDs separately so EventWatcher can retry only on
                // later filesystem-change ticks.
                if row.isNew {
                    unresolvedNewMessageRowIDs.append(row.rowID)
                    continue
                }

                // Existing rows without a chat join are orphaned. Skip them so
                // the event watcher can keep moving.
                //
                // In case there are tons of orphaned messages, don't spam the
                // logs with this message.
                if timesWarnedAboutOrphanedMessage < 10 {
                    log.error("couldn't join message \(row.rowID) to chat, dropping")
                    timesWarnedAboutOrphanedMessage += 1
                }
                continue
            }

            updatedMessages.append(UpdatedMessageChange(
                rowID: row.rowID,
                chatGUID: guid,
                isNew: row.isNew,
                wasRead: row.wasRead,
                wasEdited: row.wasEdited
            ))
        }

        return UpdatedMessagesQueryResult(
            updatedMessages: updatedMessages,
            unresolvedNewMessageRowIDs: unresolvedNewMessageRowIDs,
            nextCursor: MessageUpdatesCursor(
                lastRowID: nextLastRowID,
                lastDateRead: nextLastDateRead,
                lastDateEdited: nextLastDateEdited
            )
        )
    }
}
