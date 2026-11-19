import AppKit
import IMessageCore
import Testing
@testable import IMessage

@Test
func primaryMessagesSelectionRequiresOneUnambiguousInstance() throws {
    let app = try #require(NSWorkspace.shared.runningApplications.first { $0.processIdentifier > 0 })
    #expect(try MessagesInstanceTarget.primaryInstance(in: []) == nil)
    #expect(try MessagesInstanceTarget.primaryInstance(in: [app])?.processIdentifier == app.processIdentifier)
    #expect(throws: ErrorMessage.self) {
        try MessagesInstanceTarget.primaryInstance(in: [app, app])
    }
}
