import Foundation
import IMDatabase
import SQLite3
@testable import SQLite

final class TahoeChatDatabaseFixture {
    static let defaultChatGUID = "any;-;+15555550100"

    let chatGUID: String
    let directory: URL
    let databasePath: String
    let database: Database
    let imDatabase: IMDatabase

    init(chatGUID: String = TahoeChatDatabaseFixture.defaultChatGUID) throws {
        self.chatGUID = chatGUID
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        databasePath = directory.appendingPathComponent("chat.db").path
        database = try Database(connecting: databasePath, flags: [.readWrite, .createIfNecessary])
        try Self.createTahoeSchema(in: database)
        try database.createNoopFunction(name: "verify_chat", argumentCount: 1)
        try database.execute(sqlWithoutEscaping: "INSERT INTO chat (ROWID, guid) VALUES (1, ?)", chatGUID)

        imDatabase = try IMDatabase(messagesDataBaseURL: directory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func insertMessage(
        rowID: Int,
        guid: String? = nil,
        text: String = "",
        attributedBody: Data? = nil,
        date: Int? = nil,
        dateRead: Int = 0,
        dateEdited: Int = 0,
        service: String = "iMessage"
    ) throws {
        try database.execute(
            sqlWithoutEscaping: """
            INSERT INTO message (ROWID, guid, text, attributedBody, date, date_read, date_edited, service)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rowID,
            guid ?? "message-\(rowID)",
            text,
            attributedBody,
            date ?? rowID,
            dateRead,
            dateEdited,
            service
        )
    }

    /// Inserts non-matching filler messages so search has to scan past them.
    func insertFillerMessages(rowIDs: ClosedRange<Int>) throws {
        for rowID in rowIDs {
            try insertMessage(rowID: rowID, text: "recent filler \(rowID)")
        }
    }

    /// Builds an `attributedBody` blob in the same NSArchiver/typedstream format
    /// `chat.db` stores and `AttributedBodyDecoder` reads.
    static func attributedBody(_ string: String) -> Data {
        NSArchiver.archivedData(withRootObject: NSAttributedString(string: string))
    }

    func insertChatJoin(
        messageRowID: Int,
        chatRowID: Int = 1,
        messageDate: Int? = nil
    ) throws {
        try Self.insertChatJoin(
            messageRowID: messageRowID,
            chatRowID: chatRowID,
            messageDate: messageDate ?? messageRowID,
            into: database
        )
    }

    func insertChatJoin(
        messageRowID: Int,
        after delay: TimeInterval,
        chatRowID: Int = 1,
        messageDate: Int? = nil
    ) {
        let databasePath = databasePath
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            guard let database = try? Database(connecting: databasePath, flags: .readWrite) else {
                return
            }
            try? Self.insertChatJoin(
                messageRowID: messageRowID,
                chatRowID: chatRowID,
                messageDate: messageDate ?? messageRowID,
                into: database
            )
        }
    }

    func updateMessagePayloadData(rowID: Int, payloadData: Data) throws {
        try database.execute(sqlWithoutEscaping: "UPDATE message SET payload_data = ? WHERE ROWID = ?", payloadData, rowID)
    }

    private static func insertChatJoin(
        messageRowID: Int,
        chatRowID: Int,
        messageDate: Int,
        into database: Database
    ) throws {
        try database.execute(
            sqlWithoutEscaping: """
            INSERT INTO chat_message_join (chat_id, message_id, message_date)
            VALUES (?, ?, ?)
            """,
            chatRowID,
            messageRowID,
            messageDate
        )
    }

    private static func createTahoeSchema(in database: Database) throws {
        let schema = try String(contentsOf: schemaURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !line.hasPrefix("CREATE TABLE sqlite_sequence")
                    && !line.hasPrefix("CREATE TABLE sqlite_stat1")
            }
            .joined(separator: "\n")

        try database.executeScript(sqlWithoutEscaping: schema)
    }

    private static var schemaURL: URL {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot.appendingPathComponent("fixtures/schema-tahoe.sql")
    }
}

private extension Database {
    func executeScript(sqlWithoutEscaping sql: String) throws {
        try sql.withCString { ptr in
            var errorMessage: UnsafeMutablePointer<CChar>?
            defer {
                if let errorMessage {
                    sqlite3_free(errorMessage)
                }
            }

            let result = sqlite3_exec(connection, ptr, nil, nil, &errorMessage)
            guard result == SQLITE_OK else {
                throw SQLiteError(code: result)
            }
        }
    }

    func createNoopFunction(name: String, argumentCount: Int32) throws {
        let result = sqlite3_create_function_v2(
            connection,
            name,
            argumentCount,
            SQLITE_UTF8,
            nil,
            { context, _, _ in sqlite3_result_null(context) },
            nil,
            nil,
            nil
        )
        try SQLiteError.check(result)
    }
}
