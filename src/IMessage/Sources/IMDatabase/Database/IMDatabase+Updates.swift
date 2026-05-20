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

private let chatJoinRetryTimeout: TimeInterval = 3
private let chatJoinRetryInterval: TimeInterval = 0.05
private let chatJoinRetryIntervalNanoseconds = UInt64(chatJoinRetryInterval * 1_000_000_000)

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
    func messages(since cursor: MessageUpdatesCursor) async throws -> UpdatedMessagesQueryResult {
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

        var timesWarnedAboutOrphanedMessage = 0
        var updatedMessages: [UpdatedMessageChange] = []
        updatedMessages.reserveCapacity(rows.count)
        for row in rows {
            guard let guid = try await chatGUID(forMessageRowID: row.rowID, joinedGUID: row.chatGUID, isNew: row.isNew) else {
                // For whatever reason it's possible for messages to not be
                // joinable with chats. Right now I have one of these for a SMS
                // TOTP verification code, which might've been automatically
                // deleted in a weird way due to the autofill feature.
                //
                // New message rows can also briefly appear before their
                // chat_message_join row is visible to our connection. The helper
                // above gives that transient case a short chance to settle from
                // a fresh statement after the main query has finished. If there
                // is still no chat here, treat it as genuinely orphaned and skip
                // it so the event watcher can keep moving.
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
            nextCursor: MessageUpdatesCursor(
                lastRowID: nextLastRowID,
                lastDateRead: nextLastDateRead,
                lastDateEdited: nextLastDateEdited
            )
        )
    }

    private func chatGUID(forMessageRowID rowID: Int, joinedGUID: String?, isNew: Bool) async throws -> String? {
        if let joinedGUID {
            return joinedGUID
        }
        guard isNew else {
            return nil
        }

        log.warning("couldn't join new message \(rowID) to chat, retrying briefly")
        let deadline = Date().addingTimeInterval(chatJoinRetryTimeout)
        repeat {
            if let chatGUID = try threadIDForMessage(rowID: rowID) {
                return chatGUID
            }
            try await Task.sleep(nanoseconds: chatJoinRetryIntervalNanoseconds)
        } while Date() < deadline

        return try threadIDForMessage(rowID: rowID)
    }
}
