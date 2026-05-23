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
        lastDateRead: Date(nanosecondsSinceReferenceDate: 0),
        lastDateEdited: Date(nanosecondsSinceReferenceDate: 0)
    ))

    #expect(Date().timeIntervalSince(startedAt) < 1)
    #expect(result.updatedMessages.map(\.rowID) == [11])
    #expect(result.updatedMessages.allSatisfy { $0.isNew })
    #expect(result.updatedMessages.allSatisfy { $0.chatGUID == fixture.chatGUID })
    #expect(result.unresolvedNewMessageRowIDs == [10])
    #expect(result.nextCursor.lastRowID == 11)
}
