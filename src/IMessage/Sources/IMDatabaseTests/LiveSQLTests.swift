import Foundation
import GRDB
@testable import IMDatabase
import Testing

private enum LocalMessagesDatabase {
    static var messagesDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["IMDATABASE_TEST_MESSAGES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Messages/", isDirectory: true)
    }

    static var chatDBURL: URL {
        messagesDirectory.appendingPathComponent("chat.db")
    }

    static var isReadable: Bool {
        FileManager.default.isReadableFile(atPath: chatDBURL.path)
    }

    static let fullDiskAccessRequest: Void = {
        guard !isReadable else { return }
        do {
            try Process.run(
                URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
            )
        } catch {}
    }()

    static func requireReadable() throws {
        guard isReadable else {
            _ = fullDiskAccessRequest
            throw FullDiskAccessRequired(chatDBURL: chatDBURL)
        }
    }

    static func imDatabase() throws -> IMDatabase {
        try requireReadable()
        return try IMDatabase(messagesDataBaseURL: messagesDirectory)
    }

    static func queue() throws -> DatabaseQueue {
        try requireReadable()
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: chatDBURL.path, configuration: configuration)
    }
}

private struct FullDiskAccessRequired: Error, CustomStringConvertible {
    var chatDBURL: URL

    var description: String {
        """
        IMDatabaseLiveSQLTests need Full Disk Access to read \(chatDBURL.path).

        The test runner opened System Settings > Privacy & Security > Full Disk Access.
        Grant access to the app that launched these tests, then rerun the suite.

        Common cases:
        - Xcode test run: grant Xcode Full Disk Access.
        - Terminal swift test: grant that terminal app Full Disk Access.
        - Codex/local tool run: grant the host app Full Disk Access.

        Override the Messages directory with IMDATABASE_TEST_MESSAGES_DIR if needed.
        """
    }
}

private struct SampleChat {
    var rowID: Int
    var guid: String
    var latestMessageDate: Int?
}

private struct SampleMessage {
    var rowID: Int
    var guid: String
    var chatRowID: Int
    var chatGUID: String
    var messageDate: Int?
}

@Suite("IMDatabase live SQL", .serialized)
struct IMDatabaseLiveSQLTests {
    @Test("loads schema from local chat.db")
    func schemaLoadsAllKnownTables() throws {
        let db = try LocalMessagesDatabase.imDatabase()
        let schema = try db.schema()

        #expect(schema.sqliteSequence.has(.name))
        #expect(schema.sqliteSequence.has(.seq))
        #expect(schema.message.has(.rowID))
        #expect(schema.message.has(.guid))
        #expect(schema.message.has(.date))
        #expect(schema.message.has(.dateRead))
        #expect(schema.chat.has(.rowID))
        #expect(schema.chat.has(.guid))
        #expect(schema.chat.has(.serviceName))
        #expect(schema.handle.has(.rowID))
        #expect(schema.handle.has(.id))
        #expect(schema.attachment.has(.rowID))
        #expect(schema.attachment.has(.guid))
        #expect(schema.chatMessageJoin.has(.chatID))
        #expect(schema.chatMessageJoin.has(.messageID))
        #expect(schema.chatHandleJoin.has(.chatID))
        #expect(schema.chatHandleJoin.has(.handleID))
        #expect(schema.messageAttachmentJoin.has(.messageID))
        #expect(schema.messageAttachmentJoin.has(.attachmentID))
    }

    @Test("matches account, chat, thread GUID, and participant queries")
    func accountAndChatQueriesMatchRawSQL() throws {
        let db = try LocalMessagesDatabase.imDatabase()
        let queue = try LocalMessagesDatabase.queue()

        let expectedAccountLogins = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT DISTINCT account_login
            FROM chat
            """).compactMap { $0[0] as String? }.sorted()
        }
        #expect(try db.accountLogins().sorted() == expectedAccountLogins)

        let expectedChatCount = try queue.read { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM chat WHERE guid IS NOT NULL") ?? 0
        }
        #expect(try db.chats().count == expectedChatCount)

        let chat = try #require(try Self.latestChat(queue: queue))
        let fetchedChat = try #require(try db.chat(withGUID: chat.guid))
        #expect(fetchedChat.id == chat.rowID)
        #expect(fetchedChat.guid.description == chat.guid)

        let expectedThreadGUIDs = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: "SELECT guid FROM chat").compactMap { $0[0] as String? }.sorted()
        }
        #expect(try db.allThreadGUIDs().sorted() == expectedThreadGUIDs)

        let expectedHandles = try queue.read { rawDB in
            try Int.fetchOne(rawDB, sql: """
            SELECT COUNT(*)
            FROM chat
            INNER JOIN chat_handle_join ON chat_handle_join.chat_id = chat.ROWID
            INNER JOIN handle ON handle.ROWID = chat_handle_join.handle_id
            WHERE chat.guid = ?
            """, arguments: [chat.guid]) ?? 0
        }
        #expect(try db.handles(inChatWithGUID: chat.guid).count == expectedHandles)
    }

    @Test("matches legacy message and attachment queries")
    func legacyMessageAndAttachmentQueriesMatchRawSQL() throws {
        let db = try LocalMessagesDatabase.imDatabase()
        let queue = try LocalMessagesDatabase.queue()
        let sample = try #require(try Self.latestMessage(queue: queue))

        let fetched = try #require(try db.message(
            with: GUID<Message>(stringLiteral: sample.guid),
            withAttachments: true
        ))
        #expect(fetched.message.id == sample.rowID)
        #expect(fetched.message.guid.description == sample.guid)
        #expect(fetched.chatGUID.description == sample.chatGUID)
        #expect(fetched.message.attachments != nil)

        let expectedAttachmentCount = try queue.read { rawDB in
            try Int.fetchOne(rawDB, sql: """
            SELECT COUNT(*)
            FROM message_attachment_join AS maj
            INNER JOIN attachment AS a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
            """, arguments: [sample.rowID]) ?? 0
        }
        #expect(fetched.message.attachments?.count == expectedAttachmentCount)

        let expectedMessageIDs = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT m.ROWID
            FROM message AS m
            LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat AS c ON cmj.chat_id = c.ROWID
            WHERE c.guid = ?
            ORDER BY m.date DESC
            LIMIT 5
            """, arguments: [sample.chatGUID]).compactMap { $0[0] as Int? }
        }
        let messages = try Array(db.messages(
            in: GUID<Chat>(stringLiteral: sample.chatGUID),
            order: .newestFirst,
            limit: 5,
            withAttachments: true
        ))
        #expect(messages.map(\.id) == expectedMessageIDs)
        #expect(messages.allSatisfy { $0.attachments != nil })

        if let messageDate = sample.messageDate {
            let beforeDate = Date(nanosecondsSinceReferenceDate: messageDate)
            let expectedBeforeIDs = try queue.read { rawDB in
                try Row.fetchAll(rawDB, sql: """
                SELECT m.ROWID
                FROM message AS m
                LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
                LEFT JOIN chat AS c ON cmj.chat_id = c.ROWID
                WHERE c.guid = ? AND m.date < ?
                ORDER BY m.date DESC
                LIMIT 3
                """, arguments: databaseArguments([sample.chatGUID, messageDate])).compactMap { $0[0] as Int? }
            }
            let beforeMessages = try Array(db.messages(
                in: GUID<Chat>(stringLiteral: sample.chatGUID),
                filter: .before(beforeDate),
                order: .newestFirst,
                limit: 3,
                withAttachments: false
            ))
            #expect(beforeMessages.map(\.id) == expectedBeforeIDs)

            let expectedAfterIDs = try queue.read { rawDB in
                try Row.fetchAll(rawDB, sql: """
                SELECT m.ROWID
                FROM message AS m
                LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
                LEFT JOIN chat AS c ON cmj.chat_id = c.ROWID
                WHERE c.guid = ? AND m.date > ?
                ORDER BY m.date ASC
                LIMIT 3
                """, arguments: databaseArguments([sample.chatGUID, messageDate])).compactMap { $0[0] as Int? }
            }
            let afterMessages = try Array(db.messages(
                in: GUID<Chat>(stringLiteral: sample.chatGUID),
                filter: .after(beforeDate),
                order: .oldestFirst,
                limit: 3,
                withAttachments: false
            ))
            #expect(afterMessages.map(\.id) == expectedAfterIDs)
        }
    }

    @Test("matches mapped thread queries")
    func mappedThreadQueriesMatchRawSQL() throws {
        let db = try LocalMessagesDatabase.imDatabase()
        let queue = try LocalMessagesDatabase.queue()

        let expectedThreadIDs = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT chat.ROWID
            FROM chat
            ORDER BY (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) DESC
            LIMIT 10
            """).compactMap { $0[0] as Int? }
        }
        let threadRows = try db.mappedThreadRows(cursor: nil, direction: nil, limit: 10)
        #expect(threadRows.map(\.rowID) == expectedThreadIDs)

        if let cursor = threadRows.dropFirst().first?.msgDate {
            let rowsBeforeCursor = try db.mappedThreadRows(cursor: String(cursor), direction: .before, limit: 5)
            #expect(rowsBeforeCursor.allSatisfy { ($0.msgDate ?? Int.min) < cursor })

            let rowsAfterCursor = try db.mappedThreadRows(cursor: String(cursor), direction: .after, limit: 5)
            #expect(rowsAfterCursor.allSatisfy { ($0.msgDate ?? Int.max) > cursor })
        }

        let chat = try #require(try Self.latestChat(queue: queue))
        let threadRow = try #require(try db.mappedThreadRow(guid: chat.guid))
        #expect(threadRow.rowID == chat.rowID)
        #expect(threadRow.guid == chat.guid)

        let chatRowIDs = Array(threadRows.prefix(5).map(\.rowID))
        let participantRows = try db.mappedThreadParticipantRows(chatRowIDs: chatRowIDs)
        let expectedParticipantCounts = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT chj.chat_id, COUNT(*)
            FROM handle
            LEFT JOIN chat_handle_join AS chj ON chj.handle_id = handle.ROWID
            WHERE chj.chat_id IN (\(placeholders(count: chatRowIDs.count)))
            GROUP BY chj.chat_id
            """, arguments: StatementArguments(chatRowIDs)).reduce(into: [:]) { result, row in
                result[row[0] as Int] = row[1] as Int
            }
        }
        #expect(participantRows.mapValues(\.count) == expectedParticipantCounts)

        let unreadCounts = try db.mappedUnreadCounts(chatRowIDs: chatRowIDs)
        let expectedUnreadCounts = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT cm.chat_id, COUNT(cm.chat_id)
            FROM message AS m
            INNER JOIN chat_message_join AS cm ON m.ROWID = cm.message_id
            WHERE m.item_type == 0
              AND m.is_read == 0
              AND m.is_from_me == 0
              AND cm.chat_id IN (\(placeholders(count: chatRowIDs.count)))
            GROUP BY cm.chat_id
            """, arguments: StatementArguments(chatRowIDs)).reduce(into: [:]) { result, row in
                result[row[0] as Int] = row[1] as Int
            }
        }
        #expect(unreadCounts == expectedUnreadCounts)
    }

    @Test("matches mapped message paging and batch queries")
    func mappedMessageQueriesMatchRawSQL() throws {
        let db = try LocalMessagesDatabase.imDatabase()
        let queue = try LocalMessagesDatabase.queue()
        let chat = try #require(try Self.chatWithAtLeastMessages(queue: queue, count: 3))

        #expect(try db.mappedChatRowID(guid: chat.guid) == chat.rowID)

        let expectedNewestMessageIDs = try Self.messageIDs(
            queue: queue,
            chatRowID: chat.rowID,
            order: "DESC",
            limit: 5
        )
        let messageRows = try db.mappedMessageRows(in: chat.guid, cursor: nil, direction: nil, limit: 5)
        #expect(messageRows.map(\.rowID) == expectedNewestMessageIDs)
        #expect(messageRows.allSatisfy { $0.threadID == chat.guid })

        let cursor = try #require(try Self.messageCursor(queue: queue, chatRowID: chat.rowID, offset: 1))
        let expectedBeforeCursor = try Self.messageIDs(
            queue: queue,
            chatRowID: chat.rowID,
            cursorSQL: "AND cmj.message_date < ?",
            cursor: cursor,
            order: "DESC",
            limit: 5
        )
        let beforeCursorRows = try db.mappedMessageRows(in: chat.guid, cursor: String(cursor), direction: .before, limit: 5)
        #expect(beforeCursorRows.map(\.rowID) == expectedBeforeCursor)

        let dateExpression = try db.schema().message.has(.dateEdited)
            ? "MAX(m.date, COALESCE(m.date_edited, 0))"
            : "cmj.message_date"
        let expectedAfterCursor = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT cmj.message_id
            FROM chat_message_join AS cmj
            INNER JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ? AND \(dateExpression) > ?
            ORDER BY cmj.message_date ASC, cmj.message_id ASC
            LIMIT 5
            """, arguments: databaseArguments([chat.rowID, cursor])).compactMap { $0[0] as Int? }
        }
        let afterCursorRows = try db.mappedMessageRows(in: chat.guid, cursor: String(cursor), direction: .after, limit: 5)
        #expect(afterCursorRows.map(\.rowID) == expectedAfterCursor)

        let expectedRowsByGUID = Array(messageRows.prefix(3))
        let rowsByGUID = try db.mappedMessageRows(guids: expectedRowsByGUID.map(\.guid) + [expectedRowsByGUID[0].guid])
        #expect(Set(rowsByGUID.map(\.rowID)) == Set(expectedRowsByGUID.map(\.rowID)))

        let rowsByID = try db.mappedMessageRows(rowIDs: expectedRowsByGUID.map(\.rowID) + [expectedRowsByGUID[0].rowID])
        let expectedRowsByID = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT m.ROWID
            FROM message AS m
            WHERE m.ROWID IN (\(placeholders(count: expectedRowsByGUID.count)))
            ORDER BY m.date DESC
            """, arguments: StatementArguments(expectedRowsByGUID.map(\.rowID))).compactMap { $0[0] as Int? }
        }
        #expect(rowsByID.map(\.rowID) == expectedRowsByID)

        let latestRows = try db.mappedLatestMessageRows(chatRowIDs: [chat.rowID])
        let latestRow = try #require(latestRows[chat.guid])
        #expect(latestRow.rowID == expectedNewestMessageIDs.first)
    }

    @Test("matches mapped attachment and reaction queries")
    func mappedAttachmentAndReactionQueriesMatchRawSQL() throws {
        let db = try LocalMessagesDatabase.imDatabase()
        let queue = try LocalMessagesDatabase.queue()

        if let attachmentSample = try Self.messageWithAttachment(queue: queue) {
            let attachmentRows = try db.mappedAttachmentRows(messageRowIDs: [attachmentSample.messageRowID])
            let expectedAttachmentRows = try queue.read { rawDB in
                try Row.fetchAll(rawDB, sql: """
                SELECT m.ROWID AS msgRowID, a.filename, a.transfer_name, a.total_bytes, a.is_sticker, a.guid AS attachmentID, a.transfer_state
                FROM message AS m
                LEFT JOIN message_attachment_join AS maj ON maj.message_id = m.ROWID
                LEFT JOIN attachment AS a ON a.ROWID = maj.attachment_id
                WHERE m.ROWID = ?
                """, arguments: [attachmentSample.messageRowID])
            }
            #expect(attachmentRows.count == expectedAttachmentRows.count)
            #expect(attachmentRows.first?.msgRowID == attachmentSample.messageRowID)
            #expect(try db.attachmentFilename(guid: attachmentSample.attachmentGUID) == attachmentSample.filename)
            #expect(try db.attachmentFilename(messageRowID: attachmentSample.messageRowID) == attachmentSample.filename)
        }

        if let reactionSample = try Self.reactionTarget(queue: queue) {
            let reactionRows = try db.mappedReactionRows(
                messageGUIDs: [reactionSample.targetGUID],
                chatRowIDs: [reactionSample.chatRowID]
            )
            let expectedReactionRowIDs = try queue.read { rawDB in
                try Row.fetchAll(rawDB, sql: """
                SELECT m.ROWID
                FROM message AS m
                LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
                WHERE REPLACE(SUBSTR(associated_message_guid, INSTR(associated_message_guid, '/') + 1), 'bp:', '') = ?
                  AND cmj.chat_id = ?
                ORDER BY m.ROWID ASC
                """, arguments: databaseArguments([reactionSample.targetGUID, reactionSample.chatRowID])).compactMap { $0[0] as Int? }
            }
            #expect(reactionRows.map(\.rowID) == expectedReactionRowIDs)

            let chatGUID = try queue.read { rawDB in
                try String.fetchOne(rawDB, sql: "SELECT guid FROM chat WHERE ROWID = ?", arguments: [reactionSample.chatRowID])
            }
            if let chatGUID {
                let reactionRowsByGUID = try db.mappedReactionRows(messageGUIDs: [reactionSample.targetGUID], chatGUID: chatGUID)
                #expect(reactionRowsByGUID.map(\.rowID) == expectedReactionRowIDs)
            }
        }
    }

    @Test("matches unread state, update cursor, sent message, and delta queries")
    func updateAndUnreadQueriesMatchRawSQL() throws {
        let db = try LocalMessagesDatabase.imDatabase()
        let queue = try LocalMessagesDatabase.queue()

        let expectedStates: [String: (unreadCount: Int, lastRead: Int)] = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: unreadStatesQuery).reduce(into: [:]) { result, row in
                let guid: String = row[0]
                result[guid] = (
                    unreadCount: row[1],
                    lastRead: row[2]
                )
            }
        }
        let states = try db.chatStates()
        #expect(states.count == expectedStates.count)
        for (guid, expected) in expectedStates {
            let state = try #require(states[guid])
            #expect(state.unreadCount == expected.unreadCount)
            expectClose(state.lastReadMessageTimestamp.nanosecondsSinceReferenceDate, expected.lastRead)
        }

        let unreadSample = try #require(try Self.latestChat(queue: queue))
        let sampleUnreadCounts = try db.mappedUnreadCounts(chatRowIDs: [unreadSample.rowID])
        #expect(try db.isThreadRead(chatGUID: unreadSample.guid) == ((sampleUnreadCounts[unreadSample.rowID] ?? 0) == 0))

        let rawLastMessageRowID = try queue.read { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'message'") ?? 0
        }
        #expect(try db.lastMessageRowID() == rawLastMessageRowID)

        let rawMaxDateRead = try queue.read { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT MAX(date_read) FROM message") ?? 0
        }
        let rawMaxDateEdited = try db.schema().message.has(.dateEdited)
            ? queue.read { rawDB in
                try Int.fetchOne(rawDB, sql: "SELECT MAX(date_edited) FROM message") ?? 0
            }
            : 0
        expectClose(try db.maxMessageDateRead().nanosecondsSinceReferenceDate, rawMaxDateRead)

        let snapshot = try db.messageUpdateCursorSnapshot()
        #expect(snapshot.lastRowID == rawLastMessageRowID)
        expectClose(snapshot.lastDateRead.nanosecondsSinceReferenceDate, rawMaxDateRead)
        expectClose(snapshot.lastDateEdited.nanosecondsSinceReferenceDate, rawMaxDateEdited)

        let threshold = max(0, rawLastMessageRowID - 1000)
        let expectedSent = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT ROWID, guid
            FROM message
            WHERE is_from_me = 1 AND ROWID > ?
            """, arguments: [threshold]).map { row in
                (rowID: row[0] as Int, guid: row[1] as String)
            }
        }
        let sent = try db.sentMessageIDs(since: threshold)
        #expect(sent.map(\.rowID) == expectedSent.map(\.rowID))

        let sample = try #require(try Self.latestMessage(queue: queue))
        #expect(try db.threadIDForMessage(rowID: sample.rowID) == sample.chatGUID)

        let deltas = try db.messages(
            newerThanRowID: threshold,
            orReadSince: Date(nanosecondsSinceReferenceDate: rawMaxDateRead),
            orEditedSince: Date(nanosecondsSinceReferenceDate: rawMaxDateEdited)
        )
        let expectedDeltaRowIDs = try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT m.ROWID
            FROM message AS m
            LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat AS c ON cmj.chat_id = c.ROWID
            WHERE m.ROWID > ? AND c.guid IS NOT NULL
            ORDER BY m.ROWID ASC
            """, arguments: [threshold]).compactMap { $0[0] as Int? }
        }
        #expect(deltas.updatedMessages.map(\.rowID) == expectedDeltaRowIDs)
    }

    @Test("search results point at messages containing the query")
    func searchMessagesReturnsMatchingRows() throws {
        let db = try LocalMessagesDatabase.imDatabase()
        let queue = try LocalMessagesDatabase.queue()
        let query = "a"

        let rowIDs = try db.searchMessages(query: query, limit: 10)
        #expect(rowIDs.count <= 10)

        for rowID in rowIDs {
            let matches = try Self.messageTextMatches(rowID: rowID, query: query, queue: queue)
            #expect(matches)
        }

        let sample = try #require(try Self.latestMessage(queue: queue))
        let chatFilteredRowIDs = try db.searchMessages(query: query, chatGUID: sample.chatGUID, limit: 5)
        for rowID in chatFilteredRowIDs {
            let belongsToChat = try queue.read { rawDB in
                try Int.fetchOne(rawDB, sql: """
                SELECT COUNT(*)
                FROM chat_message_join AS cmj
                INNER JOIN chat AS c ON c.ROWID = cmj.chat_id
                WHERE cmj.message_id = ? AND c.guid = ?
                """, arguments: databaseArguments([rowID, sample.chatGUID])) ?? 0
            }
            #expect(belongsToChat > 0)
            #expect(try Self.messageTextMatches(rowID: rowID, query: query, queue: queue))
        }

        let mediaRowIDs = try db.searchMessages(query: query, mediaOnly: true, limit: 5)
        for rowID in mediaRowIDs {
            let hasAttachments = try queue.read { rawDB in
                try Int.fetchOne(rawDB, sql: "SELECT cache_has_attachments FROM message WHERE ROWID = ?", arguments: [rowID]) ?? 0
            }
            #expect(hasAttachments == 1)
            #expect(try Self.messageTextMatches(rowID: rowID, query: query, queue: queue))
        }

        for sender in ["me", "others"] {
            let senderRowIDs = try db.searchMessages(query: query, sender: sender, limit: 5)
            for rowID in senderRowIDs {
                let isFromMe = try queue.read { rawDB in
                    try Int.fetchOne(rawDB, sql: "SELECT is_from_me FROM message WHERE ROWID = ?", arguments: [rowID]) ?? -1
                }
                #expect(isFromMe == (sender == "me" ? 1 : 0))
                #expect(try Self.messageTextMatches(rowID: rowID, query: query, queue: queue))
            }
        }
    }

    private static func messageTextMatches(rowID: Int, query: String, queue: DatabaseQueue) throws -> Bool {
        try queue.read { rawDB in
            let row = try #require(try Row.fetchOne(rawDB, sql: """
            SELECT text, attributedBody
            FROM message
            WHERE ROWID = ?
            """, arguments: [rowID]))
            let plainText = row[0] as String?
            let attributedBody = row[1] as Data?
            let decodedText = attributedBody.flatMap { try? AttributedBodyDecoder.plainText(from: $0) }
            let text = decodedText?.isEmpty == false ? decodedText : plainText
            return text?.lowercased().contains(query) == true
        }
    }

    @Test("benchmarks hot local SQL paths")
    func benchmarkHotLocalSQLPaths() throws {
        let db = try LocalMessagesDatabase.imDatabase()
        let iterations = max(1, Int(ProcessInfo.processInfo.environment["IMDATABASE_BENCHMARK_ITERATIONS"] ?? "") ?? 5)
        let queue = try LocalMessagesDatabase.queue()
        let chat = try #require(try Self.chatWithAtLeastMessages(queue: queue, count: 3))
        let threadRows = try db.mappedThreadRows(cursor: nil, direction: nil, limit: 25)
        let chatRowIDs = Array(threadRows.prefix(25).map(\.rowID))
        let messageRows = try db.mappedMessageRows(in: chat.guid, cursor: nil, direction: nil, limit: 25)
        let messageRowIDs = messageRows.map(\.rowID)
        let messageGUIDs = messageRows.map(\.guid)
        let reactionSample = try Self.reactionTarget(queue: queue)

        try measure("mappedThreadRows", iterations: iterations) {
            try db.mappedThreadRows(cursor: nil, direction: nil, limit: 25).count
        }
        try measure("mappedLatestMessageRows", iterations: iterations) {
            try db.mappedLatestMessageRows(chatRowIDs: chatRowIDs).count
        }
        try measure("mappedThreadParticipantRows", iterations: iterations) {
            try db.mappedThreadParticipantRows(chatRowIDs: chatRowIDs).values.reduce(0) { $0 + $1.count }
        }
        try measure("mappedUnreadCounts", iterations: iterations) {
            try db.mappedUnreadCounts(chatRowIDs: chatRowIDs).count
        }
        try measure("mappedMessageRows.page", iterations: iterations) {
            try db.mappedMessageRows(in: chat.guid, cursor: nil, direction: nil, limit: 25).count
        }
        try measure("mappedMessageRows.rowIDs", iterations: iterations) {
            try db.mappedMessageRows(rowIDs: messageRowIDs).count
        }
        try measure("mappedMessageRows.guids", iterations: iterations) {
            try db.mappedMessageRows(guids: messageGUIDs).count
        }
        try measure("mappedAttachmentRows", iterations: iterations) {
            try db.mappedAttachmentRows(messageRowIDs: messageRowIDs).count
        }
        try measure("mappedReactionRows", iterations: iterations) {
            if let reactionSample {
                return try db.mappedReactionRows(
                    messageGUIDs: [reactionSample.targetGUID],
                    chatRowID: reactionSample.chatRowID
                ).count
            }
            return try db.mappedReactionRows(messageGUIDs: messageGUIDs, chatRowID: chat.rowID).count
        }
        try measure("messageUpdateCursorSnapshot", iterations: iterations) {
            let snapshot = try db.messageUpdateCursorSnapshot()
            return snapshot.lastRowID
        }
        try measure("chatStates", iterations: iterations) {
            try db.chatStates().count
        }
        try measure("searchMessages", iterations: iterations) {
            try db.searchMessages(query: "a", limit: 20).count
        }
    }
}

private extension IMDatabaseLiveSQLTests {
    static func latestChat(queue: DatabaseQueue) throws -> SampleChat? {
        try queue.read { rawDB in
            try Row.fetchOne(rawDB, sql: """
            SELECT c.ROWID, c.guid, MAX(cmj.message_date) AS latestMessageDate
            FROM chat AS c
            LEFT JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            WHERE c.guid IS NOT NULL
            GROUP BY c.ROWID
            ORDER BY latestMessageDate DESC
            LIMIT 1
            """).map { row in
                SampleChat(rowID: row[0] as Int, guid: row[1] as String, latestMessageDate: row[2] as Int?)
            }
        }
    }

    static func chatWithAtLeastMessages(queue: DatabaseQueue, count: Int) throws -> SampleChat? {
        try queue.read { rawDB in
            try Row.fetchOne(rawDB, sql: """
            SELECT c.ROWID, c.guid, MAX(cmj.message_date) AS latestMessageDate
            FROM chat AS c
            INNER JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            WHERE c.guid IS NOT NULL
            GROUP BY c.ROWID
            HAVING COUNT(cmj.message_id) >= ?
            ORDER BY latestMessageDate DESC
            LIMIT 1
            """, arguments: [count]).map { row in
                SampleChat(rowID: row[0] as Int, guid: row[1] as String, latestMessageDate: row[2] as Int?)
            }
        }
    }

    static func latestMessage(queue: DatabaseQueue) throws -> SampleMessage? {
        try queue.read { rawDB in
            try Row.fetchOne(rawDB, sql: """
            SELECT m.ROWID, m.guid, c.ROWID, c.guid, cmj.message_date
            FROM message AS m
            INNER JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            INNER JOIN chat AS c ON c.ROWID = cmj.chat_id
            WHERE m.guid IS NOT NULL AND c.guid IS NOT NULL
            ORDER BY m.date DESC
            LIMIT 1
            """).map { row in
                SampleMessage(
                    rowID: row[0] as Int,
                    guid: row[1] as String,
                    chatRowID: row[2] as Int,
                    chatGUID: row[3] as String,
                    messageDate: row[4] as Int?
                )
            }
        }
    }

    static func messageCursor(queue: DatabaseQueue, chatRowID: Int, offset: Int) throws -> Int? {
        try queue.read { rawDB in
            try Int.fetchOne(rawDB, sql: """
            SELECT cmj.message_date
            FROM chat_message_join AS cmj
            INNER JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
            ORDER BY cmj.message_date DESC, cmj.message_id DESC
            LIMIT 1 OFFSET \(offset)
            """, arguments: [chatRowID])
        }
    }

    static func messageIDs(
        queue: DatabaseQueue,
        chatRowID: Int,
        cursorSQL: String = "",
        cursor: Int? = nil,
        order: String,
        limit: Int
    ) throws -> [Int] {
        var arguments: [any DatabaseValueConvertible] = [chatRowID]
        if let cursor {
            arguments.append(cursor)
        }
        arguments.append(limit)
        return try queue.read { rawDB in
            try Row.fetchAll(rawDB, sql: """
            SELECT cmj.message_id
            FROM chat_message_join AS cmj
            INNER JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
            \(cursorSQL)
            ORDER BY cmj.message_date \(order), cmj.message_id \(order)
            LIMIT ?
            """, arguments: StatementArguments(arguments)).compactMap { $0[0] as Int? }
        }
    }

    static func messageWithAttachment(queue: DatabaseQueue) throws -> (messageRowID: Int, attachmentGUID: String, filename: String?)? {
        try queue.read { rawDB in
            try Row.fetchOne(rawDB, sql: """
            SELECT m.ROWID, a.guid, a.filename
            FROM message AS m
            INNER JOIN message_attachment_join AS maj ON maj.message_id = m.ROWID
            INNER JOIN attachment AS a ON a.ROWID = maj.attachment_id
            WHERE a.guid IS NOT NULL
            ORDER BY m.date DESC
            LIMIT 1
            """).map { row in
                (messageRowID: row[0] as Int, attachmentGUID: row[1] as String, filename: row[2] as String?)
            }
        }
    }

    static func reactionTarget(queue: DatabaseQueue) throws -> (targetGUID: String, chatRowID: Int)? {
        try queue.read { rawDB in
            try Row.fetchOne(rawDB, sql: """
            SELECT normalized_target_guid, chat_id
            FROM (
              SELECT
                REPLACE(SUBSTR(m.associated_message_guid, INSTR(m.associated_message_guid, '/') + 1), 'bp:', '') AS normalized_target_guid,
                cmj.chat_id AS chat_id
              FROM message AS m
              INNER JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
              WHERE m.associated_message_guid IS NOT NULL
            )
            WHERE normalized_target_guid IS NOT NULL AND normalized_target_guid != ''
            GROUP BY normalized_target_guid, chat_id
            ORDER BY COUNT(*) DESC
            LIMIT 1
            """).map { row in
                (targetGUID: row[0] as String, chatRowID: row[1] as Int)
            }
        }
    }
}

private func placeholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}

private func databaseArguments(_ values: [Any]) -> StatementArguments {
    guard let arguments = StatementArguments(values) else {
        preconditionFailure("all test SQL arguments must be database values")
    }
    return arguments
}

private func expectClose(_ actual: Int, _ expected: Int, tolerance: Int = 1_000_000) {
    #expect(abs(actual - expected) <= tolerance)
}

private func measure(_ name: String, iterations: Int, _ operation: () throws -> Int) throws {
    let clock = ContinuousClock()
    _ = try operation()

    var samples: [Double] = []
    var resultCount = 0
    for _ in 0..<iterations {
        let start = clock.now
        resultCount = try operation()
        let elapsed = start.duration(to: clock.now)
        samples.append(milliseconds(elapsed))
    }

    let average = samples.reduce(0, +) / Double(samples.count)
    let minimum = samples.min() ?? 0
    let maximum = samples.max() ?? 0
    print(String(
        format: "[IMDatabaseBench] %@ iterations=%d result_count=%d avg_ms=%.3f min_ms=%.3f max_ms=%.3f",
        name,
        iterations,
        resultCount,
        average,
        minimum,
        maximum
    ))
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
}
