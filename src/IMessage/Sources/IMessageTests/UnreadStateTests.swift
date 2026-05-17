import Foundation
import IMDatabase
import SQLite
import Testing

@Test func chatStatesUseLatestRelevantIncomingMessageUnreadState() throws {
    try withUnreadStateFixtureDatabase { db in
        let states = try db.chatStates()

        let readState = try #require(states[readThreadGUID])
        let unreadState = try #require(states[unreadThreadGUID])
        let outgoingOnlyState = try #require(states[outgoingOnlyThreadGUID])
        let hiddenLatestState = try #require(states[hiddenLatestThreadGUID])

        #expect(!readState.isUnread)
        #expect(unreadState.isUnread)
        #expect(!outgoingOnlyState.isUnread)
        #expect(!hiddenLatestState.isUnread)
        #expect(states[emptyThreadGUID] == nil)
    }
}

@Test func isThreadReadUsesLatestRelevantIncomingMessageUnreadState() throws {
    try withUnreadStateFixtureDatabase { db in
        let readThreadIsRead = try db.isThreadRead(chatGUID: readThreadGUID)
        let unreadThreadIsRead = try db.isThreadRead(chatGUID: unreadThreadGUID)
        let outgoingOnlyThreadIsRead = try db.isThreadRead(chatGUID: outgoingOnlyThreadGUID)
        let hiddenLatestThreadIsRead = try db.isThreadRead(chatGUID: hiddenLatestThreadGUID)

        #expect(readThreadIsRead)
        #expect(!unreadThreadIsRead)
        #expect(outgoingOnlyThreadIsRead)
        #expect(hiddenLatestThreadIsRead)
    }
}

private let readThreadGUID = "any;-;read-latest-incoming@example.invalid"
private let unreadThreadGUID = "any;-;unread-latest-incoming@example.invalid"
private let outgoingOnlyThreadGUID = "any;-;outgoing-only@example.invalid"
private let hiddenLatestThreadGUID = "any;-;hidden-latest@example.invalid"
private let emptyThreadGUID = "any;-;empty@example.invalid"

private func withUnreadStateFixtureDatabase(_ body: (IMDatabase) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("platform-imessage-unread-state-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try createUnreadStateFixtureDatabase(at: directory)
    try body(IMDatabase(messagesDataBaseURL: directory))
}

private func createUnreadStateFixtureDatabase(at directory: URL) throws {
    let path = directory.appendingPathComponent("chat.db").path
    let database = try Database(connecting: path, flags: [.readWrite, .createIfNecessary])

    try database.execute(sqlWithoutEscaping: """
    CREATE TABLE chat (
        guid TEXT NOT NULL,
        display_name TEXT,
        service_name TEXT NOT NULL DEFAULT 'iMessage',
        last_read_message_timestamp INTEGER NOT NULL DEFAULT 0
    )
    """)
    try database.execute(sqlWithoutEscaping: """
    CREATE TABLE message (
        is_read INTEGER NOT NULL DEFAULT 0,
        is_from_me INTEGER NOT NULL DEFAULT 0,
        item_type INTEGER NOT NULL DEFAULT 0,
        associated_message_type INTEGER DEFAULT 0,
        schedule_type INTEGER DEFAULT 0,
        date_retracted INTEGER DEFAULT 0,
        was_detonated INTEGER DEFAULT 0
    )
    """)
    try database.execute(sqlWithoutEscaping: """
    CREATE TABLE chat_message_join (
        chat_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        message_date INTEGER NOT NULL
    )
    """)

    try insertChat(database, rowID: 1, guid: readThreadGUID)
    try insertMessage(database, rowID: 101, isRead: false)
    try insertJoin(database, chatID: 1, messageID: 101, messageDate: 100)
    try insertMessage(database, rowID: 102, isRead: true)
    try insertJoin(database, chatID: 1, messageID: 102, messageDate: 200)

    try insertChat(database, rowID: 2, guid: unreadThreadGUID)
    try insertMessage(database, rowID: 201, isRead: true)
    try insertJoin(database, chatID: 2, messageID: 201, messageDate: 100)
    try insertMessage(database, rowID: 202, isRead: false)
    try insertJoin(database, chatID: 2, messageID: 202, messageDate: 200)
    try insertMessage(database, rowID: 203, isRead: false, isFromMe: true)
    try insertJoin(database, chatID: 2, messageID: 203, messageDate: 300)
    try insertMessage(database, rowID: 204, isRead: false, associatedMessageType: 2001)
    try insertJoin(database, chatID: 2, messageID: 204, messageDate: 400)
    try insertMessage(database, rowID: 205, isRead: false, itemType: 1)
    try insertJoin(database, chatID: 2, messageID: 205, messageDate: 500)

    try insertChat(database, rowID: 3, guid: outgoingOnlyThreadGUID)
    try insertMessage(database, rowID: 301, isRead: false, isFromMe: true)
    try insertJoin(database, chatID: 3, messageID: 301, messageDate: 100)

    try insertChat(database, rowID: 4, guid: hiddenLatestThreadGUID)
    try insertMessage(database, rowID: 401, isRead: true)
    try insertJoin(database, chatID: 4, messageID: 401, messageDate: 100)
    try insertMessage(database, rowID: 402, isRead: false, scheduleType: 2)
    try insertJoin(database, chatID: 4, messageID: 402, messageDate: 200)
    try insertMessage(database, rowID: 403, isRead: false, dateRetracted: 1)
    try insertJoin(database, chatID: 4, messageID: 403, messageDate: 300)
    try insertMessage(database, rowID: 404, isRead: false, wasDetonated: true)
    try insertJoin(database, chatID: 4, messageID: 404, messageDate: 400)

    try insertChat(database, rowID: 5, guid: emptyThreadGUID)
}

private func insertChat(_ database: Database, rowID: Int, guid: String) throws {
    try database.execute(
        sqlWithoutEscaping: "INSERT INTO chat (ROWID, guid, service_name, last_read_message_timestamp) VALUES (?, ?, 'iMessage', 0)",
        rowID,
        guid
    )
}

private func insertMessage(
    _ database: Database,
    rowID: Int,
    isRead: Bool,
    isFromMe: Bool = false,
    itemType: Int = 0,
    associatedMessageType: Int = 0,
    scheduleType: Int = 0,
    dateRetracted: Int = 0,
    wasDetonated: Bool = false
) throws {
    try database.execute(
        sqlWithoutEscaping: """
        INSERT INTO message (
            ROWID,
            is_read,
            is_from_me,
            item_type,
            associated_message_type,
            schedule_type,
            date_retracted,
            was_detonated
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rowID,
        isRead ? 1 : 0,
        isFromMe ? 1 : 0,
        itemType,
        associatedMessageType,
        scheduleType,
        dateRetracted,
        wasDetonated ? 1 : 0
    )
}

private func insertJoin(_ database: Database, chatID: Int, messageID: Int, messageDate: Int) throws {
    try database.execute(
        sqlWithoutEscaping: "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)",
        chatID,
        messageID,
        messageDate
    )
}
