import Collections
import Foundation
import SQLiteData

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
            try fetchAllSQL(MessageQueryRow.self, db: db, sql: """
            \(messagesQuerySharedPrelude)
            WHERE m.guid = ?
            """, arguments: [guid]).compactMap { row -> (Message, GUID<Chat>)? in
                guard let chatGUID = row.chatGUID else {
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
            let rows = try fetchAllSQL(MessageQueryRow.self, db: db, sql: """
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
    init(row: MessageQueryRow) throws {
        self = try Message(
            id: row.rowID,
            guid: GUID<Message>(row.guid),
            balloonBundleID: row.balloonBundleID,
            threadOriginatorGUID: row.threadOriginatorGUID.map(GUID<Message>.init(stringLiteral:)),
            text: row.text.map {
                Sensitive(.messageText, hiding: $0)
            },
            attributedBody: row.attributedBody.flatMap {
                try Sensitive(.messageAttributedBody, hiding: AttributedBodyDecoder.attributedString(from: $0))
            },
            isFromMe: row.isFromMe,
            isSent: row.isSent,
            date: row.date,
            dateRead: row.dateRead,
            summaryInfo: row.summaryInfo.map(Message.SummaryInfo.init(blob:)),
            )
    }
}

@Selection
private struct MessageQueryRow {
    let chatGUID: String?
    @Column("ROWID")
    let rowID: Int
    let guid: String
    @Column("balloon_bundle_id")
    let balloonBundleID: String?
    @Column("thread_originator_guid")
    let threadOriginatorGUID: String?
    let text: String?
    let attributedBody: Data?
    @Column("is_from_me", as: LooseBoolRepresentation.self)
    let isFromMe: Bool
    @Column("is_sent", as: LooseBoolRepresentation.self)
    let isSent: Bool
    @Column(as: IMCoreDateRepresentation.self)
    let date: Date?
    @Column("date_read", as: IMCoreDateRepresentation.self)
    let dateRead: Date?
    @Column("message_summary_info")
    let summaryInfo: Data?
}
