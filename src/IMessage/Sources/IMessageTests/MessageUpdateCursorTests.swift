import Foundation
import IMDatabase
import SQLite3
@testable import SQLite
import Testing

@Test func newMessageWaitsBrieflyForChatJoin() throws {
    let fixture = try MessageUpdateCursorFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 10)
    try fixture.insertMessage(rowID: 11)
    try fixture.insertChatJoin(messageRowID: 11)
    fixture.insertChatJoin(messageRowID: 10, after: 0.05)

    let result = try fixture.imDatabase.messages(since: MessageUpdatesCursor(
        lastRowID: 9,
        lastDateRead: Date(nanosecondsSinceReferenceDate: 0),
        lastDateEdited: Date(nanosecondsSinceReferenceDate: 0)
    ))

    #expect(result.updatedMessages.map(\.rowID) == [10, 11])
    #expect(result.updatedMessages.allSatisfy { $0.isNew })
    #expect(result.updatedMessages.allSatisfy { $0.chatGUID == MessageUpdateCursorFixture.chatGUID })
    #expect(result.nextCursor.lastRowID == 11)
}

private final class MessageUpdateCursorFixture {
    static let chatGUID = "any;-;+15555550100"

    let directory: URL
    let databasePath: String
    let database: Database
    let imDatabase: IMDatabase

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        databasePath = directory.appendingPathComponent("chat.db").path
        database = try Database(connecting: databasePath, flags: [.readWrite, .createIfNecessary])
        try Self.createTahoeSchema(in: database)
        try database.createNoopFunction(name: "verify_chat", argumentCount: 1)
        try database.execute(sqlWithoutEscaping: "INSERT INTO chat (ROWID, guid) VALUES (1, ?)", Self.chatGUID)

        imDatabase = try IMDatabase(messagesDataBaseURL: directory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func insertMessage(rowID: Int) throws {
        try database.execute(
            sqlWithoutEscaping: """
            INSERT INTO message (ROWID, guid, date, date_read, date_edited, service)
            VALUES (?, ?, ?, 0, 0, 'iMessage')
            """,
            rowID,
            "message-\(rowID)",
            rowID
        )
    }

    func insertChatJoin(messageRowID: Int) throws {
        try insertChatJoin(messageRowID: messageRowID, into: database)
    }

    func insertChatJoin(messageRowID: Int, after delay: TimeInterval) {
        let databasePath = databasePath
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            let database = try? Database(connecting: databasePath, flags: .readWrite)
            try? database.map { try self.insertChatJoin(messageRowID: messageRowID, into: $0) }
        }
    }

    private func insertChatJoin(messageRowID: Int, into database: Database) throws {
        try database.execute(
            sqlWithoutEscaping: """
            INSERT INTO chat_message_join (chat_id, message_id, message_date)
            VALUES (1, ?, ?)
            """,
            messageRowID,
            messageRowID
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
