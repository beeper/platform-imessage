import Collections
import Foundation
import GRDB

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
SELECT c.guid, m.ROWID, m.guid, m.balloon_bundle_id, m.thread_originator_guid, m.text, m.attributedBody, m.is_from_me, m.is_sent, m.date, m.date_read, m.message_summary_info
FROM message m
LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat c ON cmj.chat_id = c.ROWID
"""

public extension IMDatabase {
    func message(
        with guid: GUID<Message>,
        withAttachments includeAttachments: Bool = true,
        ) throws -> (message: Message, chatGUID: GUID<Chat>)? {
        let result = try read { db in
            try Row.fetchAll(db, sql: """
            \(messagesQuerySharedPrelude)
            WHERE m.guid = ?
            """, arguments: [guid]).compactMap { row -> (Message, GUID<Chat>)? in
                guard let chatGUID = row.optionalString(at: 0) else {
                    // drop orphaned (not within a chat) messages
                    return nil
                }
                return try (Message(row: row), GUID(chatGUID))
            }.first
        }

        guard let (initialMessage, chatGUID) = result else {
            return nil
        }

        var message = initialMessage
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
        var messages = OrderedDictionary<Message.ID, Message>()
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
            \(messagesQuerySharedPrelude)
            WHERE c.guid = ?
            \(filter.map { "AND m.\($0.sqlFragment)" } ?? "")
            ORDER BY m.date \(order.sqlKeyword)
            LIMIT ?
            """, arguments: sqlArguments([chatGUID, limit]))
            for row in rows {
                let message = try Message(row: row)
                messages[message.id] = message
            }
        }

        if includeAttachments {
            try hydrateAttachments(for: &messages)
        }

        return messages.values
    }
}

private extension Message {
    init(row: Row) throws {
        // (skipping `c.guid`)
        self = try Message(
            id: row.requiredInt(at: 1),
            guid: GUID<Message>(row.requiredString(at: 2)),
            balloonBundleID: row.optionalString(at: 3),
            threadOriginatorGUID: row.optionalString(at: 4).map(GUID<Message>.init(stringLiteral:)),
            text: row.optionalString(at: 5).map {
                Sensitive(.messageText, hiding: $0)
            },
            attributedBody: row.optionalData(at: 6).flatMap {
                try Sensitive(.messageAttributedBody, hiding: AttributedBodyDecoder.attributedString(from: $0))
            },
            isFromMe: row.looseBool(at: 7),
            isSent: row.looseBool(at: 8),
            date: row.imCoreDate(at: 9),
            dateRead: row.imCoreDate(at: 10),
            summaryInfo: row.optionalData(at: 11).map(Message.SummaryInfo.init(blob:)),
            )
    }
}
