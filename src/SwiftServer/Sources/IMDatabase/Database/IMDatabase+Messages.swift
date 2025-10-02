import Collections
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
    let sqlFragment: String
    init(escapedSQLFragment: String) {
        self.sqlFragment = escapedSQLFragment
    }

    public static func before(_ date: Date) -> Self {
        MessageQueryFilter(escapedSQLFragment: "date < \(date.nanosecondsSinceReferenceDate)")
    }

    public static func after(_ date: Date) -> Self {
        MessageQueryFilter(escapedSQLFragment: "date > \(date.nanosecondsSinceReferenceDate)")
    }
}

let messagesQuerySharedPrelude = """
SELECT c.guid, m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.is_sent, m.date, m.date_read, m.message_summary_info
FROM message m
LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat c ON cmj.chat_id = c.ROWID
"""

public extension IMDatabase {
    func message(
        with guid: GUID<Message>,
        withAttachments includeAttachments: Bool = true,
    ) throws -> (message: Message, chatGUID: GUID<Chat>)? {
        let statement = try cachedStatement(forEscapedSQL: """
        \(messagesQuerySharedPrelude)
        WHERE m.guid = ?
        """).reset()
        try statement.bind(guid)

        guard var (message, chatGUID) = try statement.compactMapRowsUntilDone({ row -> (Message, GUID<Chat>)? in
            guard let chatGUID = try row[0].optionalConverting(String.self) else {
                // drop orphaned (not within a chat) messages
                return nil
            }
            return try (Message(row: row), GUID(chatGUID))
        }).first else {
            return nil
        }

        if includeAttachments {
            try hydrateAttachments(for: &message)
        }

        return (message, chatGUID)
    }

    func messages(
        in chatGUID: GUID<Chat>,
        filter: MessageQueryFilter? = nil,
        order: DateOrdering = .newestFirst,
        limit: Int = 50,
        withAttachments includeAttachments: Bool = true,
    ) throws -> some Collection<Message> {
        let statement = try cachedStatement(forEscapedSQL: """
        \(messagesQuerySharedPrelude)
        WHERE c.guid = ?
        \(filter.map { "AND m.\($0.sqlFragment)" } ?? "")
        ORDER BY m.date \(order.sqlKeyword)
        LIMIT ?
        """).reset()
        try statement.bind(chatGUID, limit)

        var messages = OrderedDictionary<Message.ID, Message>()
        try statement.stepUntilDone { row in
            let message = try Message(row: row)
            messages[message.id] = message
        }

        if includeAttachments {
            try hydrateAttachments(for: &messages)
        }

        return messages.values
    }
}

private extension Message {
    init(row: borrowing Row) throws {
        // (skipping `c.guid`)
        self = try Message(
            id: row[1].expect(Int.self),
            guid: GUID<Message>(row[2].expect(String.self)),
            text: row[3].optional(String.self).map {
                Sensitive(.messageText, hiding: $0)
            },
            attributedBody: row[4].optional(Data.self).flatMap {
                try Sensitive(.messageAttributedBody, hiding: unarchiveAttributedString(from: $0))
            },
            isFromMe: row[5].looseBool(),
            isSent: row[6].looseBool(),
            date: row[7].imCoreDate(),
            dateRead: row[8].imCoreDate(),
            summaryInfo: row[9].optionalConverting(Data.self).map(Message.SummaryInfo.init(blob:)),
        )
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
