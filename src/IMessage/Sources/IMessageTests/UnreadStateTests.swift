import Foundation
import IMDatabase
import SQLite
import Testing

@Test func chatStatesUseLatestMessageUnreadState() throws {
    try withUnreadStateFixtureDatabase { db in
        let states = try db.chatStates()

        let readState = try #require(states[readThreadGUID])
        let unreadState = try #require(states[unreadThreadGUID])
        let outgoingLatestState = try #require(states[outgoingLatestThreadGUID])
        let reactionLatestState = try #require(states[reactionLatestThreadGUID])
        let actionLatestState = try #require(states[actionLatestThreadGUID])

        #expect(!readState.isUnread)
        #expect(unreadState.isUnread)
        #expect(outgoingLatestState.isUnread)
        #expect(reactionLatestState.isUnread)
        #expect(actionLatestState.isUnread)
        #expect(states[emptyThreadGUID] == nil)
    }
}

@Test func isThreadReadUsesLatestMessageUnreadState() throws {
    try withUnreadStateFixtureDatabase { db in
        let readThreadIsRead = try db.isThreadRead(chatGUID: readThreadGUID)
        let unreadThreadIsRead = try db.isThreadRead(chatGUID: unreadThreadGUID)
        let outgoingLatestThreadIsRead = try db.isThreadRead(chatGUID: outgoingLatestThreadGUID)
        let reactionLatestThreadIsRead = try db.isThreadRead(chatGUID: reactionLatestThreadGUID)
        let actionLatestThreadIsRead = try db.isThreadRead(chatGUID: actionLatestThreadGUID)

        #expect(readThreadIsRead)
        #expect(!unreadThreadIsRead)
        #expect(!outgoingLatestThreadIsRead)
        #expect(!reactionLatestThreadIsRead)
        #expect(!actionLatestThreadIsRead)
    }
}

private let readThreadGUID = "any;-;read-latest-incoming@example.invalid"
private let unreadThreadGUID = "any;-;unread-latest-incoming@example.invalid"
private let outgoingLatestThreadGUID = "any;-;outgoing-latest@example.invalid"
private let reactionLatestThreadGUID = "any;-;reaction-latest@example.invalid"
private let actionLatestThreadGUID = "any;-;action-latest@example.invalid"
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

    try insertChat(database, rowID: 3, guid: outgoingLatestThreadGUID)
    try insertMessage(database, rowID: 300, isRead: true)
    try insertJoin(database, chatID: 3, messageID: 300, messageDate: 100)
    try insertMessage(database, rowID: 301, isRead: false, isFromMe: true)
    try insertJoin(database, chatID: 3, messageID: 301, messageDate: 200)

    try insertChat(database, rowID: 4, guid: reactionLatestThreadGUID)
    try insertMessage(database, rowID: 400, isRead: true)
    try insertJoin(database, chatID: 4, messageID: 400, messageDate: 100)
    try insertMessage(database, rowID: 401, isRead: false, associatedMessageType: 2001)
    try insertJoin(database, chatID: 4, messageID: 401, messageDate: 200)

    try insertChat(database, rowID: 5, guid: actionLatestThreadGUID)
    try insertMessage(database, rowID: 500, isRead: true)
    try insertJoin(database, chatID: 5, messageID: 500, messageDate: 100)
    try insertMessage(database, rowID: 501, isRead: false, itemType: 1)
    try insertJoin(database, chatID: 5, messageID: 501, messageDate: 200)

    try insertChat(database, rowID: 6, guid: emptyThreadGUID)
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
    associatedMessageType: Int = 0
) throws {
    try database.execute(
        sqlWithoutEscaping: """
        INSERT INTO message (
            ROWID,
            is_read,
            is_from_me,
            item_type,
            associated_message_type
        ) VALUES (?, ?, ?, ?, ?)
        """,
        rowID,
        isRead ? 1 : 0,
        isFromMe ? 1 : 0,
        itemType,
        associatedMessageType
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
