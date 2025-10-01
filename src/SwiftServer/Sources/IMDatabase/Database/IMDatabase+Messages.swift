import ExceptionCatcher
import Foundation
import SQLite
import SwiftServerFoundation

public enum DateOrdering {
    case newestFirst
    case oldestFirst

    var sqlKeyword: String {
        switch self {
        case .newestFirst: "DESC"
        case .oldestFirst: "ASC"
        }
    }
}

public struct MessageQueryFilter {
    let sql: String
    init(escapedSQL: String) {
        self.sql = escapedSQL
    }

    public static func before(_ date: Date) -> Self {
        MessageQueryFilter(escapedSQL: "date < ?")
    }

    public static func after(_ date: Date) -> Self {
        MessageQueryFilter(escapedSQL: "date > ?")
    }
}

public extension IMDatabase {
    func messages(
        in chatGUID: GUID<Chat>,
        filter: MessageQueryFilter? = nil,
        order: DateOrdering = .newestFirst,
        limit: Int = 50,
        withAttachments includeAttachments: Bool = true,
    ) throws -> some Collection<Message> {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.is_sent, m.date, m.date_read
        FROM message m
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE c.guid = ?
        \(filter.map { "AND m.\($0.sql)" } ?? "")
        ORDER BY date \(order.sqlKeyword)
        LIMIT ?
        """).reset()
        if let filter {
            try statement.bind(chatGUID, filter.sql, limit)
        } else {
            try statement.bind(chatGUID, limit)
        }

        var messages = [Message.ID: Message]()
        try statement.stepUntilDone { row in
            let id = try row[0].expect(Int.self)
            let guid = try GUID<Message>(row[1].expect(String.self))

            messages[id] = try Message(
                id: id,
                guid: guid,
                text: row[2].optional(String.self).map {
                    Sensitive(.messageText, hiding: $0)
                },
                attributedBody: row[3].optional(Data.self).flatMap {
                    try Sensitive(.messageAttributedBody, hiding: unarchiveAttributedString(from: $0))
                },
                isFromMe: row[4].looseBool(),
                isSent: row[5].looseBool(),
                date: row[6].imCoreDate(),
                dateRead: row[7].imCoreDate(),
            )
        }

        if includeAttachments {
            try hydrateAttachments(for: &messages)
        }

        return messages.values
    }

    private func hydrateAttachments(for messages: inout [Message.ID: Message]) throws {
        let messageRowIDs = messages.values.map { "\($0.id)" }

        let statement = try Statement.prepare(escapedSQL: """
        SELECT m.ROWID, a.ROWID, a.guid, a.filename, a.transfer_name, a.is_sticker, a.transfer_state, a.uti
        FROM message m
        INNER JOIN message_attachment_join maj ON maj.message_id = m.ROWID
        INNER JOIN attachment a ON a.ROWID = maj.attachment_id
        WHERE m.ROWID IN (\(messageRowIDs.joined(separator: ",")))
        """, for: database)
        try statement.stepUntilDone { row in
            let messageRowID = try row[0].expect(Int.self)
            let attachmentRowID = try row[1].expect(Int.self)
            let attachmentGUID = try GUID<Attachment>(row[2].expect(String.self))
            let fileName = try row[3].optionalConverting(String.self)
            let transferName = try row[4].optionalConverting(String.self)
            let isSticker = try row[5].looseBool()
            let transferState = try Attachment.TransferState(rawValue: row[6].expectConverting(Int.self))
            let uti = try row[7].optionalConverting(String.self)

            guard messages[messageRowID] != nil else {
                return
            }

            if messages[messageRowID]!.attachments == nil {
                messages[messageRowID]!.attachments = []
            }
            messages[messageRowID]!.attachments!.append(
                Attachment(
                    id: attachmentRowID,
                    guid: attachmentGUID,
                    fileName: fileName,
                    transferName: transferName,
                    isSticker: isSticker,
                    transferState: transferState,
                    uti: uti,
                )
            )
        }
    }
}

private extension Column {
    consuming func imCoreDate() throws -> Date? {
        guard let nanoseconds = try optionalConverting(Int.self) else {
            return nil
        }

        // For unknown reasons `0` can be present instead of `NULL`. Treat them as the same.
        guard nanoseconds > 0 else {
            return nil
        }

        // Explicitly check for bogus dates. If you let these escape into the rest of the
        // program then an integer overflow might make everything implode.
        let date = Date(nanosecondsSinceReferenceDate: nanoseconds)
        guard date < .distantFuture else {
            return nil
        }

        return date
    }

    consuming func looseBool() throws -> Bool {
        guard let integer = try optionalConverting(Int.self) else {
            return false
        }

        return integer == 1
    }
}

private func unarchiveAttributedString(from data: Data) throws -> NSAttributedString {
    guard let unarchiver = try NSUnarchiver(forReadingWith: data) else {
        throw ErrorMessage("couldn't create NSUnarchiver")
    }

    // this is technically unsafe (https://iosdevelopers.slack.com/archives/C031X84F6/p1658329958824499?thread_ts=1658147279.256379&cid=C031X84F6)
    let anything = try ExceptionCatcher.catch { unarchiver.decodeObject() }
    guard let attributedString = anything as? NSAttributedString else {
        throw ErrorMessage("couldn't cast to attributed string (was actually \(type(of: anything))")
    }

    return attributedString
}
