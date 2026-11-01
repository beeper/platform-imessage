import AppKit
import IMessageCore
import Testing
@testable import IMessage

@Test
func primaryMessagesSelectionRequiresOneUnambiguousInstance() throws {
    let app = NSRunningApplication.current
    #expect(try MessagesInstanceTarget.primaryInstance(in: []) == nil)
    #expect(try MessagesInstanceTarget.primaryInstance(in: [app])?.processIdentifier == app.processIdentifier)
    #expect(throws: ErrorMessage.self) {
        try MessagesInstanceTarget.primaryInstance(in: [app, app])
    }
}
