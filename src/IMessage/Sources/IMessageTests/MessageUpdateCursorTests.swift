import Foundation
import IMDatabase
import Testing

@Test func newMessageWaitsBrieflyForChatJoin() throws {
    let fixture = try TahoeChatDatabaseFixture()
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
    #expect(result.updatedMessages.allSatisfy { $0.chatGUID == fixture.chatGUID })
    #expect(result.nextCursor.lastRowID == 11)
}
