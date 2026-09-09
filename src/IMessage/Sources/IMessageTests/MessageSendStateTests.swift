import Foundation
import IMDatabase
@testable import IMessage
import Testing

@Test func messageSendStatesReturnsTheRowsThatStillExist() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }
    try fixture.insertMessage(rowID: 1, guid: "message-1", date: 1_000_000)
    try fixture.insertMessage(rowID: 2, guid: "message-2", date: 2_000_000)
    try fixture.insertMessage(rowID: 3, guid: "message-3", date: 3_000_000)
    try fixture.database.execute(sqlWithoutEscaping: "UPDATE message SET is_from_me = 1, is_sent = 1 WHERE ROWID = 2")
    try fixture.database.execute(sqlWithoutEscaping: "UPDATE message SET is_from_me = 1, is_sent = 0, error = 22 WHERE ROWID = 3")

    let states = try fixture.imDatabase.messageSendStates(guids: ["message-2", "missing", "message-1", "message-3", "message-2"])
    #expect(Set(states.map(\.guid)) == ["message-1", "message-2", "message-3"])
    #expect(states.count == 3)
    #expect(states.first { $0.guid == "message-2" }?.isSent == true)
    #expect(states.first { $0.guid == "message-1" }?.isSent == false)
    #expect(states.first { $0.guid == "message-3" }?.error == 22)
    #expect(states.first { $0.guid == "message-3" }?.date == 3_000_000)
    #expect(try fixture.imDatabase.messageSendStates(guids: []).isEmpty)
}
