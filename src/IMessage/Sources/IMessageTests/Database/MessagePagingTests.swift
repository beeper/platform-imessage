@testable import IMDatabase
import Testing

@Test func messagesAfterACursorIncludeOlderMessagesEditedSince() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.database.execute(sqlWithoutEscaping: "INSERT INTO chat (ROWID, guid) VALUES (2, 'any;-;other')")
    for rowID in 1 ... 5 {
        try fixture.insertMessage(rowID: rowID, date: rowID * 10, dateEdited: rowID == 1 ? 45 : 0)
        try fixture.insertChatJoin(messageRowID: rowID, messageDate: rowID * 10)
    }
    try fixture.insertMessage(rowID: 6, date: 60, dateEdited: 70)
    try fixture.insertChatJoin(messageRowID: 6, chatRowID: 2, messageDate: 60)

    let rows = try fixture.imDatabase.mappedMessageRows(in: fixture.chatGUID, cursor: "30", direction: .after)
    #expect(rows.map(\.rowID) == [1, 4, 5])

    let limited = try fixture.imDatabase.mappedMessageRows(in: fixture.chatGUID, cursor: "30", direction: .after, limit: 2)
    #expect(limited.map(\.rowID) == [1, 4])
}

@Test func messagesAfterACursorWorkWithoutAnEditDateColumn() throws {
    let fixture = try TahoeChatDatabaseFixture(
        chatGUID: "iMessage;-;+15555550100",
        schema: TahoeChatDatabaseFixture.montereySchema
    )
    defer { fixture.cleanup() }

    for rowID in 1 ... 5 {
        try fixture.database.execute(
            sqlWithoutEscaping: "INSERT INTO message (ROWID, guid, date) VALUES (?, ?, ?)",
            rowID,
            "message-\(rowID)",
            rowID * 10
        )
        try fixture.insertChatJoin(messageRowID: rowID, messageDate: rowID * 10)
    }

    let rows = try fixture.imDatabase.mappedMessageRows(in: fixture.chatGUID, cursor: "30", direction: .after)
    #expect(rows.map(\.rowID) == [4, 5])
}

@Test func messagesInAChatHonourTheDateFilterAndOrder() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.database.execute(sqlWithoutEscaping: "INSERT INTO chat (ROWID, guid) VALUES (2, 'any;-;other')")
    for rowID in 1 ... 8 {
        try fixture.insertMessage(rowID: rowID, date: rowID * 10)
        try fixture.insertChatJoin(messageRowID: rowID, chatRowID: rowID.isMultiple(of: 2) ? 2 : 1, messageDate: rowID * 10)
    }
    let chat = GUID<Chat>(fixture.chatGUID)

    let before = try fixture.imDatabase.messages(
        in: chat, filter: .before(nanosecondsSinceReferenceDate: 70), order: .newestFirst, limit: 2, withAttachments: false
    )
    #expect(before.map(\.id) == [5, 3])

    let after = try fixture.imDatabase.messages(
        in: chat, filter: .after(nanosecondsSinceReferenceDate: 10), order: .oldestFirst, limit: 2, withAttachments: false
    )
    #expect(after.map(\.id) == [3, 5])

    #expect(try fixture.imDatabase.messages(in: chat, withAttachments: false).map(\.id) == [7, 5, 3, 1])
}
