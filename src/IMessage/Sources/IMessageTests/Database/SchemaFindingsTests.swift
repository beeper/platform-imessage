import IMDatabase
@testable import IMessage
import Testing

private extension ChatDatabaseFixture {
    func insertChat(rowID: Int, serviceName: String? = nil) throws {
        try database.execute(
            sqlWithoutEscaping: "INSERT INTO chat (ROWID, guid, service_name) VALUES (?, ?, ?)",
            rowID,
            "any;-;chat-\(rowID)",
            serviceName
        )
    }

    func markRecentlyDeleted(messageRowID: Int, chatRowID: Int = 1) throws {
        try database.execute(
            sqlWithoutEscaping: "INSERT INTO chat_recoverable_message_join (chat_id, message_id, delete_date) VALUES (?, ?, 1)",
            chatRowID,
            messageRowID
        )
    }

    func insertIncomingMessage(rowID: Int, chatRowID: Int = 1, isRead: Int = 0, isFinished: Int = 1, isSystemMessage: Int = 0) throws {
        try insertMessage(rowID: rowID)
        try database.execute(
            sqlWithoutEscaping: "UPDATE message SET is_read = ?, is_finished = ?, is_system_message = ? WHERE ROWID = ?",
            isRead,
            isFinished,
            isSystemMessage,
            rowID
        )
        try insertChatJoin(messageRowID: rowID, chatRowID: chatRowID)
    }

    func insertReaction(rowID: Int, to associatedMessageGUID: String, chatRowID: Int = 1) throws {
        try insertMessage(rowID: rowID)
        try database.execute(
            sqlWithoutEscaping: "UPDATE message SET associated_message_guid = ?, associated_message_type = 2000 WHERE ROWID = ?",
            associatedMessageGUID,
            rowID
        )
        try insertChatJoin(messageRowID: rowID, chatRowID: chatRowID)
    }
}

@Test func globalSearchSkipsRecentlyDeletedMessages() throws {
    let fixture = try ChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 1, text: "project status kept")
    try fixture.insertChatJoin(messageRowID: 1)
    try fixture.insertMessage(rowID: 2, text: "project status deleted")
    try fixture.markRecentlyDeleted(messageRowID: 2)

    #expect(try fixture.imDatabase.searchMessages(query: "project status") == [1])
}

@Test func globalSearchWorksWithoutRecentlyDeletedTable() throws {
    let fixture = try ChatDatabaseFixture(
        chatGUID: "iMessage;-;+15555550100",
        schema: ChatDatabaseSchema.monterey
    )
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 1, text: "project status")

    #expect(try fixture.imDatabase.searchMessages(query: "project status") == [1])
}

@Test func threadListSkipsChatsWhoseMessagesAreAllRecentlyDeleted() throws {
    let fixture = try ChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 1)
    try fixture.insertChatJoin(messageRowID: 1)
    try fixture.insertChat(rowID: 2)
    try fixture.insertMessage(rowID: 2)
    try fixture.markRecentlyDeleted(messageRowID: 2, chatRowID: 2)
    try fixture.insertChat(rowID: 3)

    let threadRows = try fixture.imDatabase.mappedThreadRows(cursor: nil, direction: nil)

    #expect(threadRows.map(\.rowID) == [1, 3])
}

@Test func unreadCountsIgnoreSystemAndUnfinishedMessages() throws {
    let fixture = try ChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertIncomingMessage(rowID: 1)
    try fixture.insertIncomingMessage(rowID: 2, isSystemMessage: 1)
    try fixture.insertIncomingMessage(rowID: 3, isFinished: 0)

    #expect(try fixture.imDatabase.mappedUnreadCounts(chatRowIDs: [1]) == [1: 1])
}

@Test func unreadStateIgnoresSystemAndUnfinishedMessages() throws {
    let fixture = try ChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertIncomingMessage(rowID: 1, isRead: 1)
    try fixture.insertIncomingMessage(rowID: 2, isSystemMessage: 1)
    try fixture.insertIncomingMessage(rowID: 3, isFinished: 0)

    #expect(try fixture.imDatabase.isThreadRead(chatGUID: fixture.chatGUID))
    #expect(try fixture.imDatabase.chatStates()[fixture.chatGUID]?.isUnread == false)
}

@Test func unreadStateStillReportsUnreadMessages() throws {
    let fixture = try ChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertIncomingMessage(rowID: 1, isRead: 1)
    try fixture.insertIncomingMessage(rowID: 2)

    #expect(try !fixture.imDatabase.isThreadRead(chatGUID: fixture.chatGUID))
    #expect(try fixture.imDatabase.chatStates()[fixture.chatGUID]?.isUnread == true)
}

@Test func reactionRowsMatchEveryAssociatedGUIDForm() throws {
    let fixture = try ChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 1, guid: "target-1")
    try fixture.insertChatJoin(messageRowID: 1)
    try fixture.insertReaction(rowID: 2, to: "target-1")
    try fixture.insertReaction(rowID: 3, to: "bp:target-1")
    try fixture.insertReaction(rowID: 4, to: "p:1/target-1")
    try fixture.insertReaction(rowID: 5, to: "p:0/other-target")
    try fixture.insertChat(rowID: 2)
    try fixture.insertReaction(rowID: 6, to: "p:0/target-1", chatRowID: 2)

    let reactionRows = try fixture.imDatabase.mappedReactionRows(messageGUIDs: ["target-1"], chatRowIDs: [1])

    #expect(reactionRows.map(\.rowID) == [2, 3, 4])
}

@Test func reactionRowsAreFoundAcrossSeveralChats() throws {
    let fixture = try ChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertChat(rowID: 2)
    try fixture.insertMessage(rowID: 1, guid: "target-1")
    try fixture.insertChatJoin(messageRowID: 1)
    try fixture.insertMessage(rowID: 2, guid: "target-2")
    try fixture.insertChatJoin(messageRowID: 2, chatRowID: 2)
    try fixture.insertReaction(rowID: 3, to: "p:0/target-2", chatRowID: 2)
    try fixture.insertReaction(rowID: 4, to: "p:0/target-1")

    let reactionRows = try fixture.imDatabase.mappedReactionRows(messageGUIDs: ["target-1", "target-2"], chatRowIDs: [1, 2])

    #expect(reactionRows.map(\.rowID) == [3, 4])
}

@Test(arguments: [ChatDatabaseSchema.tahoe, ChatDatabaseSchema.monterey])
func latestVisibleMessageWithoutThreadSkipsReactions(schema: String) throws {
    let fixture = try ChatDatabaseFixture(schema: schema)
    defer { fixture.cleanup() }

    for rowID in 1 ... 3 {
        try fixture.insertMessage(rowID: rowID)
        try fixture.insertChatJoin(messageRowID: rowID)
    }
    try fixture.database.execute(sqlWithoutEscaping: "UPDATE message SET associated_message_type = 2000 WHERE ROWID = 3")

    #expect(try fixture.imDatabase.mappedLatestVisibleMessageRow(offset: 0)?.rowID == 2)
    #expect(try fixture.imDatabase.mappedLatestVisibleMessageRow(offset: 1)?.rowID == 1)
    #expect(try fixture.imDatabase.mappedLatestVisibleMessageRow(offset: 2) == nil)
}

@Test func chatLookupToleratesMissingServiceName() throws {
    let fixture = try ChatDatabaseFixture()
    defer { fixture.cleanup() }

    #expect(try fixture.imDatabase.chat(withGUID: fixture.chatGUID)?.id == 1)
}

@Test func smsThreadsAreDetectedFromServiceNameWhenTheGUIDIsUniversal() throws {
    #expect(ThreadMapper.isSMS(guid: "SMS;-;+15555550100", serviceName: nil))
    #expect(ThreadMapper.isSMS(guid: "RCS;-;+15555550100", serviceName: nil))
    #expect(ThreadMapper.isSMS(guid: "any;-;+15555550100", serviceName: "SMS"))
    #expect(ThreadMapper.isSMS(guid: "any;-;+15555550100", serviceName: "RCS"))
    #expect(ThreadMapper.isSMS(guid: "any;-;+15555550100", serviceName: "SatelliteSMS"))
    #expect(!ThreadMapper.isSMS(guid: "any;-;+15555550100", serviceName: "iMessage"))
    #expect(Chat.ServiceName(rawValue: "SatelliteSMS").isSMS)
    #expect(!Chat.ServiceName(rawValue: "iMessage").isSMS)
    #expect(!ThreadMapper.isSMS(guid: "any;-;+15555550100", serviceName: nil))
    #expect(!ThreadMapper.isSMS(guid: "iMessage;-;+15555550100", serviceName: "iMessage"))

    let fixture = try ChatDatabaseFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 2, serviceName: "SMS")

    #expect(try fixture.imDatabase.mappedThreadRow(guid: "any;-;chat-2")?.serviceName == "SMS")
}
