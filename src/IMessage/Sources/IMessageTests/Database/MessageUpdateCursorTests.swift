import Foundation
import IMDatabase
import Testing

@Test func newMessageWithMissingChatJoinIsReturnedAsUnresolvedImmediately() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 10)
    try fixture.insertMessage(rowID: 11)
    try fixture.insertChatJoin(messageRowID: 11)

    let startedAt = Date()
    let result = try fixture.imDatabase.messages(since: MessageUpdatesCursor(
        lastRowID: 9,
        lastDateReadNanoseconds: 0,
        lastDateEditedNanoseconds: 0
    ))

    #expect(Date().timeIntervalSince(startedAt) < 1)
    #expect(result.updatedMessages.map(\.rowID) == [11])
    #expect(result.updatedMessages.allSatisfy { $0.isNew })
    #expect(result.updatedMessages.allSatisfy { $0.chatGUID == fixture.chatGUID })
    #expect(result.unresolvedNewMessageRowIDs == [10])
    #expect(result.nextCursor.lastRowID == 11)
}

@Test func extremeCursorDatesDoNotOverflowWhenRebound() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let result = try fixture.imDatabase.messages(since: MessageUpdatesCursor(
        lastRowID: Int.max,
        lastDateReadNanoseconds: Int64.max,
        lastDateEditedNanoseconds: Int64.max
    ))

    #expect(result.updatedMessages.isEmpty)
}

@Test func messageUpdateCursorSnapshotKeepsRawDateIntegers() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let exactDateRead = Int64.max - 1
    let exactDateEdited = Int64.max - 2
    try fixture.insertMessage(rowID: 10, dateRead: exactDateRead, dateEdited: exactDateEdited)

    let cursor = try fixture.imDatabase.messageUpdateCursorSnapshot()

    #expect(cursor.lastDateReadNanoseconds == exactDateRead)
    #expect(cursor.lastDateEditedNanoseconds == exactDateEdited)
}

@Test func messageUpdatesCompareRawDateCursorIntegers() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let cursorDateRead = Int64.max - 1
    let updatedDateRead = Int64.max
    try fixture.insertMessage(rowID: 10, dateRead: updatedDateRead)
    try fixture.insertChatJoin(messageRowID: 10)

    let result = try fixture.imDatabase.messages(since: MessageUpdatesCursor(
        lastRowID: 10,
        lastDateReadNanoseconds: cursorDateRead,
        lastDateEditedNanoseconds: 0
    ))

    #expect(result.updatedMessages.map(\.rowID) == [10])
    #expect(result.updatedMessages.first?.wasRead == true)
    #expect(result.nextCursor.lastDateReadNanoseconds == updatedDateRead)
}

@Test func messageUpdatesReturnARowMatchingEveryCursorComponentOnce() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 10, dateRead: 100, dateEdited: 100)
    try fixture.insertChatJoin(messageRowID: 10)
    try fixture.insertMessage(rowID: 11, dateRead: 200)
    try fixture.insertChatJoin(messageRowID: 11)
    try fixture.insertMessage(rowID: 12, dateEdited: 300)
    try fixture.insertChatJoin(messageRowID: 12)
    try fixture.insertMessage(rowID: 13, dateRead: 400, dateEdited: 400)
    try fixture.insertChatJoin(messageRowID: 13)

    let result = try fixture.imDatabase.messages(since: MessageUpdatesCursor(
        lastRowID: 12,
        lastDateReadNanoseconds: 150,
        lastDateEditedNanoseconds: 150
    ))

    #expect(result.updatedMessages.map(\.rowID) == [11, 12, 13])
    #expect(result.updatedMessages.map(\.isNew) == [false, false, true])
    #expect(result.updatedMessages.map(\.wasRead) == [true, false, true])
    #expect(result.updatedMessages.map(\.wasEdited) == [false, true, true])
    #expect(result.nextCursor.lastRowID == 13)
    #expect(result.nextCursor.lastDateReadNanoseconds == 400)
    #expect(result.nextCursor.lastDateEditedNanoseconds == 400)
}

@Test func messageUpdatesWorkWithoutDateEditedColumn() throws {
    let fixture = try TahoeChatDatabaseFixture(
        chatGUID: "iMessage;-;+15555550100",
        schema: TahoeChatDatabaseFixture.montereySchema
    )
    defer { fixture.cleanup() }

    for (rowID, dateRead) in [(10, 100), (11, 200), (12, 0)] {
        try fixture.database.execute(
            sqlWithoutEscaping: "INSERT INTO message (ROWID, guid, date, date_read) VALUES (?, ?, ?, ?)",
            rowID,
            "message-\(rowID)",
            rowID,
            dateRead
        )
        try fixture.insertChatJoin(messageRowID: rowID)
    }

    let snapshot = try fixture.imDatabase.messageUpdateCursorSnapshot()
    #expect(snapshot.lastRowID == 12)
    #expect(snapshot.lastDateReadNanoseconds == 200)
    #expect(snapshot.lastDateEditedNanoseconds == 0)

    let result = try fixture.imDatabase.messages(since: MessageUpdatesCursor(
        lastRowID: 11,
        lastDateReadNanoseconds: 150,
        lastDateEditedNanoseconds: 0
    ))

    #expect(result.updatedMessages.map(\.rowID) == [11, 12])
    #expect(result.updatedMessages.map(\.isNew) == [false, true])
    #expect(result.updatedMessages.map(\.wasRead) == [true, false])
    #expect(result.updatedMessages.allSatisfy { !$0.wasEdited })
    #expect(result.updatedMessages.allSatisfy { $0.chatGUID == fixture.chatGUID })
    #expect(result.nextCursor.lastRowID == 12)
    #expect(result.nextCursor.lastDateReadNanoseconds == 200)
    #expect(result.nextCursor.lastDateEditedNanoseconds == 0)
}
