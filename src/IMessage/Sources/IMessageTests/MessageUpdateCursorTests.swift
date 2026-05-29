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
