import Foundation
@testable import IMDatabase
import IMessageCore
import SQLite3
@testable import SQLite

/// A large, deterministic `chat.db` built from a schema dump, for checking how
/// much work each query does. Built once per variant and shared by the process.
///
/// Shape: chat 1 is a group holding 30% of all messages, chats 2-20 share
/// another 30%, and the rest are small. A twentieth of messages are tapbacks
/// (all in chat 1), a twenty-fifth carry an attachment, and a few are in
/// Recently Deleted where the schema has it.
final class SyntheticChatDatabase: @unchecked Sendable {
    enum UnreadProfile: String, CaseIterable, Sendable {
        /// About 50 unread messages, all among the newest.
        case light
        /// About 13% of messages unread: small chats that were never opened
        /// plus the recent tail of the big group.
        case heavy
    }

    struct Variant: Hashable, Sendable, CustomStringConvertible {
        let schema: String
        let unread: UnreadProfile

        var description: String { "\(schema) \(unread.rawValue)" }
    }

    /// Oldest, a middle release without the macOS 26 unread indexes, and newest.
    static let schemas = ["11.0.1-20B29", "15.6.1-24G90", "27.2.1-26B131"]
    static let variants = schemas.flatMap { schema in UnreadProfile.allCases.map { Variant(schema: schema, unread: $0) } }

    static let messageCount = 200_000
    static let chatCount = 400
    static let hugeChatRowID = 1
    static let smallChatRowID = chatCount
    static let baseDate = 700_000_000 * nanosecondsPerSecond
    private static let nanosecondsPerSecond = 1_000_000_000
    private static let messageSpacing = 60 * nanosecondsPerSecond

    private static let chatGUIDPrefix = "any;-;chat-"
    private static let messageGUIDPrefix = "msg-"
    private static let groupRoomName = "chat1room"
    /// Chats 1 through this hold 60% of the messages; later chats are small.
    private static let busyChatCount = 20
    /// The newest messages, which are the unread ones in the light profile.
    private static let recentMessageCount = 100

    static func chatGUID(_ rowID: Int) -> String { "\(chatGUIDPrefix)\(rowID)" }
    static func messageGUID(_ rowID: Int) -> String { "\(messageGUIDPrefix)\(rowID)" }
    static func messageDate(_ rowID: Int) -> Int { baseDate + rowID * messageSpacing }

    let imDatabase: IMDatabase

    private init(directory: URL) throws {
        // The app adds its own indexes on first open, so the synthetic database has them too.
        imDatabase = try IMDatabase(messagesDataBaseURL: directory, createIndexes: true)
    }

    // MARK: - Shared instances

    /// One lock per schema, so the schemas build in parallel while a schema's
    /// heavy variant waits for the light file it is copied from.
    private static let instancesBySchema = Dictionary(
        uniqueKeysWithValues: schemas.map { ($0, Protected<[UnreadProfile: SyntheticChatDatabase]>([:])) }
    )
    private static let root: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-synthetic-\(ProcessInfo.processInfo.processIdentifier)")
        atexit { try? FileManager.default.removeItem(at: SyntheticChatDatabase.root) }
        return root
    }()

    static func shared(_ variant: Variant) throws -> SyntheticChatDatabase {
        try instancesBySchema[variant.schema]!.withLock { instances in
            if let instance = instances[variant.unread] {
                return instance
            }
            let lightFile = try lightDatabaseFile(schema: variant.schema)
            let file = variant.unread == .light ? lightFile : try heavyCopy(of: lightFile, schema: variant.schema)
            let instance = try SyntheticChatDatabase(directory: file.deletingLastPathComponent())
            instances[variant.unread] = instance
            return instance
        }
    }

    // MARK: - Generation

    private static func databaseFile(schema: String, unread: UnreadProfile) throws -> URL {
        let directory = root.appendingPathComponent("\(schema)-\(unread.rawValue)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("chat.db")
    }

    private static func lightDatabaseFile(schema: String) throws -> URL {
        let file = try databaseFile(schema: schema, unread: .light)
        if !FileManager.default.fileExists(atPath: file.path) {
            try populate(file: file, schema: schema)
        }
        return file
    }

    private static func heavyCopy(of lightFile: URL, schema: String) throws -> URL {
        let file = try databaseFile(schema: schema, unread: .heavy)
        try FileManager.default.copyItem(at: lightFile, to: file)
        let database = try Database(connecting: file.path, flags: .readWrite)
        try database.execute(
            sqlWithoutEscaping: """
            UPDATE message SET is_read = 0, date_read = 0
            WHERE is_from_me = 0 AND ROWID IN (
              SELECT message_id FROM chat_message_join
              WHERE (chat_id > \(busyChatCount) AND chat_id % 2 = 1) OR (chat_id = \(hugeChatRowID) AND message_id > ?)
            )
            """,
            messageCount * 8 / 10
        )
        return file
    }

    private static func populate(file: URL, schema: String) throws {
        let database = try Database(connecting: file.path, flags: [.readWrite, .createIfNecessary])
        // Without a larger cache the message table's many indexes thrash while loading.
        for pragma in ["journal_mode = OFF", "synchronous = OFF", "cache_size = -400000"] {
            try database.execute(sqlWithoutEscaping: "PRAGMA \(pragma)")
        }
        try TahoeChatDatabaseFixture.createSchema(named: schema, in: database)
        // Messages' triggers call functions only its own process registers.
        let triggers = try Statement.prepare(escapedSQL: "SELECT name FROM sqlite_master WHERE type = 'trigger'", for: database)
            .mapRowsUntilDone { try $0[0].expect(String.self) }
        for trigger in triggers {
            try database.execute(sqlWithoutEscaping: "DROP TRIGGER \"\(trigger)\"")
        }

        // Every statement below derives a row's shape from its number `i` with these.
        let chats = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(chatCount))"
        let messages = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(messageCount))"
        let inHugeChat = "(i % 10 < 3)"
        let chatOfMessage = """
        CASE
          WHEN \(inHugeChat) THEN \(hugeChatRowID)
          WHEN i % 10 < 6 THEN 2 + (i / 10) % \(busyChatCount - 1)
          ELSE \(busyChatCount + 1) + (i * 7919) % \(chatCount - busyChatCount)
        END
        """
        let isFromMe = "(((i * 2654435761) >> 7) & 1)"
        let isUnread = "(NOT \(isFromMe) AND i > \(messageCount - recentMessageCount))"
        let isReaction = "(i % 10 = 1 AND (i / 10) % 2 = 0)"
        let hasAttachment = "(i % 25 = 3)"
        let isRecentlyDeleted = "(i % 5000 = 9)"
        let date = "(\(baseDate) + i * \(messageSpacing))"
        let hasDateEdited = try database.tableColumns("message").contains("date_edited")
        let hasRecoverable = try !database.tableColumns("chat_recoverable_message_join").isEmpty

        try database.execute(sqlWithoutEscaping: "BEGIN")
        try database.execute(sqlWithoutEscaping: """
        \(chats)
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name, room_name, account_login, last_read_message_timestamp)
        SELECT i, '\(chatGUIDPrefix)' || i, 'chat-' || i, CASE WHEN i % 3 = 0 THEN 'SMS' ELSE 'iMessage' END,
          CASE WHEN i = \(hugeChatRowID) THEN '\(groupRoomName)' END, 'E:me@example.com', 0
        FROM n
        """)
        try database.execute(sqlWithoutEscaping: """
        \(chats)
        INSERT INTO handle (ROWID, id, service) SELECT i, '+1555' || printf('%07d', i), 'iMessage' FROM n
        """)
        try database.execute(sqlWithoutEscaping: """
        \(chats)
        INSERT INTO chat_handle_join (chat_id, handle_id)
        SELECT i, i FROM n UNION ALL SELECT \(hugeChatRowID), i FROM n WHERE i BETWEEN 2 AND \(busyChatCount)
        """)
        try database.execute(sqlWithoutEscaping: """
        \(messages)
        INSERT INTO message (
          ROWID, guid, text, handle_id, service, date, date_read, is_from_me, is_read, item_type,
          is_finished, is_system_message, associated_message_guid, associated_message_type,
          cache_roomnames, destination_caller_id, cache_has_attachments\(hasDateEdited ? ", date_edited" : "")
        )
        SELECT
          i, '\(messageGUIDPrefix)' || i,
          CASE WHEN i % 500 = 0 THEN 'the needle is here ' || i ELSE 'lorem ipsum dolor ' || i END,
          CASE WHEN \(isFromMe) THEN 0 ELSE \(chatOfMessage) END,
          'iMessage', \(date),
          CASE WHEN \(isFromMe) OR \(isUnread) THEN 0 ELSE \(date) + \(5 * nanosecondsPerSecond) END,
          \(isFromMe),
          NOT (\(isFromMe) OR \(isUnread)),
          CASE WHEN i % 3000 = 5 THEN 1 ELSE 0 END,
          1, 0,
          CASE WHEN \(isReaction) THEN 'p:0/\(messageGUIDPrefix)' || (i - 1) END,
          CASE WHEN \(isReaction) THEN 2000 ELSE 0 END,
          CASE WHEN \(inHugeChat) THEN '\(groupRoomName)' END,
          CASE WHEN \(isFromMe) THEN '+15550000000' END,
          \(hasAttachment)\(hasDateEdited ? ", CASE WHEN i % 1000 = 11 THEN \(date) + \(messageSpacing) ELSE 0 END" : "")
        FROM n
        """)
        try database.execute(sqlWithoutEscaping: """
        \(messages)
        INSERT INTO chat_message_join (chat_id, message_id, message_date)
        SELECT \(chatOfMessage), i, \(date) FROM n WHERE NOT \(hasRecoverable ? isRecentlyDeleted : "0")
        """)
        if hasRecoverable {
            try database.execute(sqlWithoutEscaping: """
            \(messages)
            INSERT INTO chat_recoverable_message_join (chat_id, message_id, delete_date)
            SELECT \(chatOfMessage), i, \(date) FROM n WHERE \(isRecentlyDeleted)
            """)
        }
        try database.execute(sqlWithoutEscaping: """
        \(messages)
        INSERT INTO attachment (ROWID, guid, original_guid, filename, transfer_name, transfer_state, total_bytes)
        SELECT i, 'att-' || i, 'att-' || i, '~/Library/Messages/Attachments/' || i || '.jpg', i || '.jpg', 5, 1000
        FROM n WHERE \(hasAttachment)
        """)
        try database.execute(sqlWithoutEscaping: """
        \(messages)
        INSERT INTO message_attachment_join (message_id, attachment_id) SELECT i, i FROM n WHERE \(hasAttachment)
        """)
        try database.execute(sqlWithoutEscaping: "COMMIT")
    }
}

// MARK: - Measuring query work

extension IMDatabase {
    /// Runs `body` and returns how many SQLite virtual machine steps it took,
    /// to the nearest hundred. Unlike wall-clock time this is the same on every
    /// run, so a query that starts scanning a table shows up as a step count
    /// that grew with the table.
    func countingSteps(_ body: () throws -> Void) rethrows -> Int {
        var ticks = 0
        try withUnsafeMutablePointer(to: &ticks) { ticks in
            sqlite3_progress_handler(database.connection, stepsPerTick, { context in
                context?.assumingMemoryBound(to: Int.self).pointee += 1
                return 0
            }, ticks)
            defer { sqlite3_progress_handler(database.connection, 0, nil, nil) }
            try body()
        }
        return ticks * Int(stepsPerTick)
    }
}

private let stepsPerTick: Int32 = 100
