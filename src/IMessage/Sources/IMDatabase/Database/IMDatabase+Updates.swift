import Foundation
import Logging
import SQLiteData

private let log = Logger(label: "imdb.updates")

package struct UpdatedMessageChange {
    package var rowID: Int
    package var chatGUID: String
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
        let messageSchema = try schema().message
        let dateEditedExpression = messageSchema.has(.dateEdited)
            ? "m.\(MessageTable.Column.dateEdited.sqlName)"
            : "0"
        var newestMessageRowID: Int?
        var latestMessageDateRead: Date?
        var latestDateEdited: Date?
        var timesWarnedAboutOrphanedMessage = 0

        let updatedMessages: [UpdatedMessageChange] = try read { db in
            try fetchAllSQL(
                UpdatedMessageRow.self,
                db: db,
                sql: updatedMessagesSinceQuery(dateEditedExpression: dateEditedExpression),
                arguments: [
                    lastRowID,
                    lastDateRead.nanosecondsSinceReferenceDate,
                    lastDateEdited.nanosecondsSinceReferenceDate,
                ]
            ).compactMap { row in
                let messageRowID = row.messageRowID
                let isNew = messageRowID > lastRowID
                if isNew {
                    newestMessageRowID = max(messageRowID, newestMessageRowID ?? 0)
                }

                var wasRead = false
                var wasEdited = false

                if let dateRead = row.dateRead {
                    wasRead = dateRead > lastDateRead
                    if wasRead {
                        latestMessageDateRead = if let latestMessageDateRead {
                            max(dateRead, latestMessageDateRead)
                        } else {
                            dateRead
                        }
                    }
                }

                if let dateEdited = row.dateEdited {
                    wasEdited = dateEdited > lastDateEdited
                    if wasEdited {
                        latestDateEdited = if let latestDateEdited {
                            max(dateEdited, latestDateEdited)
                        } else {
                            dateEdited
                        }
                    }
                }

                guard let guid = row.chatGUID else {
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
        }

        return UpdatedMessagesQueryResult(
            updatedMessages: updatedMessages,
            latestMessageRowID: newestMessageRowID,
            latestMessageDateRead: latestMessageDateRead,
            latestDateEdited: latestDateEdited
        )
    }
}

@Selection
private struct UpdatedMessageRow {
    @Column("ROWID")
    let messageRowID: Int
    @Column("date_read", as: IMCoreDateRepresentation.self)
    let dateRead: Date?
    @Column("date_edited", as: IMCoreDateRepresentation.self)
    let dateEdited: Date?
    @Column("guid")
    let chatGUID: String?
}

private func updatedMessagesSinceQuery(dateEditedExpression: String) -> String {
    """
    SELECT
        m.\(MessageTable.Column.rowID.sqlName),
        m.\(MessageTable.Column.dateRead.sqlName),
        \(dateEditedExpression) AS \(MessageTable.Column.dateEdited.sqlName),
        c.\(ChatTable.Column.guid.sqlName)
    FROM
        \(MessageTable.sqlName) m
    LEFT JOIN \(ChatMessageJoinTable.sqlName) cmj ON cmj.\(ChatMessageJoinTable.Column.messageID.sqlName) = m.\(MessageTable.Column.rowID.sqlName)
    LEFT JOIN \(ChatTable.sqlName) c ON cmj.\(ChatMessageJoinTable.Column.chatID.sqlName) = c.\(ChatTable.Column.rowID.sqlName)
    WHERE
        m.\(MessageTable.Column.rowID.sqlName) > ? OR m.\(MessageTable.Column.dateRead.sqlName) > ? OR \(dateEditedExpression) > ?
    ORDER BY
        m.\(MessageTable.Column.rowID.sqlName) ASC
    """
}
