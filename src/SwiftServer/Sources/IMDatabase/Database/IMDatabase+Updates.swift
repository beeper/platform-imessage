import Foundation
import Logging

private let log = Logger(label: "imdb.updates")

let updatedChatsSinceQuery = """
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
GROUP BY
    c.guid
ORDER BY
    date DESC
"""

let recoverablyDeletedMessagesSinceQuery = """
SELECT
    crmj.delete_date,
    c.guid,
    m.guid,
    m.part_count,
    m.subject
FROM
    chat_recoverable_message_join crmj
INNER JOIN chat c ON c.ROWID = crmj.chat_id
INNER JOIN message m ON m.ROWID = crmj.message_id
WHERE
    crmj.delete_date > ?
ORDER BY
    crmj.delete_date ASC
"""

let removedRecoverableMessagesSinceQuery = """
SELECT
    ROWID,
    chat_guid,
    message_guid,
    part_index
FROM
    unsynced_removed_recoverable_messages
WHERE
    ROWID > ?
ORDER BY
    ROWID ASC
"""

let latestRecoverableDeleteDateQuery = """
SELECT
    MAX(delete_date)
FROM
    chat_recoverable_message_join
"""

let latestRemovedRecoverableMessageRowIDQuery = """
SELECT
    MAX(ROWID)
FROM
    unsynced_removed_recoverable_messages
"""

public struct UpdatedChatsQueryResult {
    public var updatedChats: [ChatRef]
    /// This maximum is local to the set of updated chats.
    public var latestMessageRowID: Int?
    /// This maximum is local to the set of updated chats.
    public var latestMessageDateRead: Date?
    public var latestDateEdited: Date?
}

public struct RecoverablyDeletedMessage {
    public var deleteDate: Date
    public var chatGUID: String
    public var messageGUID: String
    public var partCount: Int
    public var hasSubject: Bool
}

public struct RemovedRecoverableMessage {
    public var rowID: Int
    public var chatGUID: String
    public var messageGUID: String
    public var partIndex: Int?
}

public struct DeletedMessagesQueryResult {
    public var recoverablyDeletedMessages: [RecoverablyDeletedMessage]
    public var latestRecoverableDeleteDate: Date?
    public var removedRecoverableMessages: [RemovedRecoverableMessage]
    public var latestRemovedRecoverableMessageRowID: Int?
}

public extension IMDatabase {
    func chats(withMessagesNewerThanRowID lastRowID: Int, orReadSince lastDateRead: Date, orEditedSince lastDateEdited: Date) throws -> UpdatedChatsQueryResult {
        let statement = try cachedStatement(forEscapedSQL: updatedChatsSinceQuery)

        try statement.reset()
        try statement.bind(lastRowID, lastDateRead.nanosecondsSinceReferenceDate, lastDateEdited.nanosecondsSinceReferenceDate)

        var newestMessageRowID: Int?
        var latestMessageDateRead: Date?
        var latestDateEdited: Date?
        var timesWarnedAboutOrphanedMessage = 0

        let updatedChats: [ChatRef] = try statement.compactMapRowsUntilDone { row in
            let messageRowID = try row[0].expect(Int.self)
            newestMessageRowID = max(messageRowID, newestMessageRowID ?? 0)

            dateRead: do {
                // IMCore typically uses `0` to represent absence, but fall back
                // to `0` explicitly just in case.
                let nanoseconds = try row[1].optional(Int.self) ?? 0

                // If the message hasn't been read yet or has a bogus read date,
                // then don't update the "latest read date" at all. I'm not sure
                // what causes bogus read dates, but if you let it leak into the
                // rest of the program then it can cause an integer overflow
                // crash.
                guard nanoseconds > 0, nanoseconds < .max else {
                    break dateRead
                }

                let dateRead = Date(nanosecondsSinceReferenceDate: nanoseconds)
                latestMessageDateRead = if let latestMessageDateRead, dateRead < .distantFuture {
                    max(dateRead, latestMessageDateRead)
                } else {
                    dateRead
                }
            }

            dateEdited: do {
                let nanoseconds = try row[2].optional(Int.self) ?? 0
                guard nanoseconds > 0, nanoseconds < .max else { break dateEdited }
                let dateEdited = Date(nanosecondsSinceReferenceDate: nanoseconds)
                latestDateEdited = if let latestDateEdited, dateEdited < .distantFuture {
                    max(dateEdited, latestDateEdited)
                } else {
                    dateEdited
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

            return ChatRef(rowID: rowID, guid: guid)
        }

        return UpdatedChatsQueryResult(
            updatedChats: updatedChats,
            latestMessageRowID: newestMessageRowID,
            latestMessageDateRead: latestMessageDateRead,
            latestDateEdited: latestDateEdited
        )
    }

    func latestRecoverableMessageDeleteDate() throws -> Date {
        guard #available(macOS 13, *) else { return .distantPast }

        let statement = try cachedStatement(forEscapedSQL: latestRecoverableDeleteDateQuery)
        try statement.reset()

        let nanoseconds = try statement.compactMapRowsUntilDone { try $0[0].optional(Int.self) }.first ?? 0
        guard nanoseconds > 0 else { return .distantPast }
        return Date(nanosecondsSinceReferenceDate: nanoseconds)
    }

    func latestRemovedRecoverableMessageRowID() throws -> Int {
        guard #available(macOS 13, *) else { return 0 }

        let statement = try cachedStatement(forEscapedSQL: latestRemovedRecoverableMessageRowIDQuery)
        try statement.reset()
        return try statement.compactMapRowsUntilDone { try $0[0].optional(Int.self) }.first ?? 0
    }

    func deletedMessages(
        sinceRecoverableDeleteDate lastRecoverableDeleteDate: Date,
        andRemovedRecoverableRowID lastRemovedRecoverableRowID: Int
    ) throws -> DeletedMessagesQueryResult {
        guard #available(macOS 13, *) else {
            return DeletedMessagesQueryResult(
                recoverablyDeletedMessages: [],
                latestRecoverableDeleteDate: nil,
                removedRecoverableMessages: [],
                latestRemovedRecoverableMessageRowID: nil
            )
        }

        let recoverableStatement = try cachedStatement(forEscapedSQL: recoverablyDeletedMessagesSinceQuery)
        try recoverableStatement.reset()
        try recoverableStatement.bind(lastRecoverableDeleteDate.nanosecondsSinceReferenceDate)

        var latestRecoverableDeleteDate: Date?
        let recoverablyDeletedMessages = try recoverableStatement.mapRowsUntilDone { row in
            let deleteDate = Date(nanosecondsSinceReferenceDate: try row[0].expect(Int.self))
            latestRecoverableDeleteDate = max(deleteDate, latestRecoverableDeleteDate ?? .distantPast)

            return try RecoverablyDeletedMessage(
                deleteDate: deleteDate,
                chatGUID: row[1].expect(String.self),
                messageGUID: row[2].expect(String.self),
                partCount: row[3].optional(Int.self) ?? 0,
                hasSubject: row[4].optional(String.self)?.isEmpty == false
            )
        }

        let removedStatement = try cachedStatement(forEscapedSQL: removedRecoverableMessagesSinceQuery)
        try removedStatement.reset()
        try removedStatement.bind(lastRemovedRecoverableRowID)

        var latestRemovedRecoverableMessageRowID: Int?
        let removedRecoverableMessages = try removedStatement.mapRowsUntilDone { row in
            let rowID = try row[0].expect(Int.self)
            latestRemovedRecoverableMessageRowID = max(rowID, latestRemovedRecoverableMessageRowID ?? 0)

            return try RemovedRecoverableMessage(
                rowID: rowID,
                chatGUID: row[1].expect(String.self),
                messageGUID: row[2].expect(String.self),
                partIndex: row[3].optional(Int.self)
            )
        }

        return DeletedMessagesQueryResult(
            recoverablyDeletedMessages: recoverablyDeletedMessages,
            latestRecoverableDeleteDate: latestRecoverableDeleteDate,
            removedRecoverableMessages: removedRecoverableMessages,
            latestRemovedRecoverableMessageRowID: latestRemovedRecoverableMessageRowID
        )
    }
}
