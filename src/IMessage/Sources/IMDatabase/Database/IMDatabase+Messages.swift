import Collections
import Foundation
import SQLite

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
    let comparison: String
    let dateNanoseconds: Int64

    public static func before(nanosecondsSinceReferenceDate dateNanoseconds: Int64) -> Self {
        MessageQueryFilter(comparison: "<", dateNanoseconds: dateNanoseconds)
    }

    public static func after(nanosecondsSinceReferenceDate dateNanoseconds: Int64) -> Self {
        MessageQueryFilter(comparison: ">", dateNanoseconds: dateNanoseconds)
    }
}

private let messagesQuerySelection = """
SELECT c.guid, m.ROWID, m.guid, m.balloon_bundle_id, m.thread_originator_guid, m.text, m.attributedBody, m.is_from_me, m.is_sent, m.date, m.date_read, m.message_summary_info
"""


public extension IMDatabase {
    func message(
        with guid: GUID<Message>,
        withAttachments includeAttachments: Bool = true,
        ) throws -> (message: Message, chatGUID: GUID<Chat>)? {
        let statement = try cachedStatement(forEscapedSQL: """
        \(messagesQuerySelection)
        FROM message m
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE m.guid = ?
        """).reset()
        try statement.bind(guid)

        guard let (initialMessage, chatGUID) = try statement.compactMapRowsUntilDone({ row -> (Message, GUID<Chat>)? in
            guard let chatGUID = try row[0].optionalConverting(String.self) else {
                // drop orphaned (not within a chat) messages
                return nil
            }
            return try (Message(row: row), GUID(chatGUID))
        }).first else {
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
        // Start from the chat's own date index. Walking message by date and
        // filtering on the chat reads every message in between for a quiet chat.
        let statement = try cachedStatement(forEscapedSQL: """
        \(messagesQuerySelection)
        FROM chat c
        CROSS JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
        CROSS JOIN message m ON m.ROWID = cmj.message_id
        WHERE c.guid = ?
        \(filter.map { "AND cmj.message_date \($0.comparison) ?" } ?? "")
        ORDER BY cmj.message_date \(order.sqlKeyword)
        LIMIT ?
        """).reset()
        if let filter {
            try statement.bind(chatGUID, filter.dateNanoseconds, limit)
        } else {
            try statement.bind(chatGUID, limit)
        }

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
        let dateNanoseconds = try row[9].imCoreDateNanoseconds()
        let dateReadNanoseconds = try row[10].imCoreDateNanoseconds()

        // (skipping `c.guid`)
        self = try Message(
            id: row[1].expect(Int.self),
            guid: GUID<Message>(row[2].expect(String.self)),
            balloonBundleID: try row[3].optional(String.self),
            threadOriginatorGUID: try row[4].optional(String.self).map(GUID<Message>.init(stringLiteral:)),
            text: row[5].optional(String.self).map {
                Sensitive(.messageText, hiding: $0)
            },
            attributedBody: row[6].optional(Data.self).flatMap {
                try Sensitive(.messageAttributedBody, hiding: AttributedBodyDecoder.attributedString(from: $0))
            },
            isFromMe: row[7].looseBool(),
            isSent: row[8].looseBool(),
            dateNanosecondsSinceReferenceDate: dateNanoseconds,
            dateReadNanosecondsSinceReferenceDate: dateReadNanoseconds,
            summaryInfo: row[11].optionalConverting(Data.self).map(Message.SummaryInfo.init(blob:)),
            )
    }
}
