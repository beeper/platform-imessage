import Testing
@testable import SwiftServer

@Test func messageDeletionIDsForSinglePartMessage() {
    #expect(messageDeletionIDs(messageGUID: "message-guid", partCount: 1, hasSubject: false) == ["message-guid"])
}

@Test func messageDeletionIDsForMultipartMessage() {
    #expect(messageDeletionIDs(messageGUID: "message-guid", partCount: 3, hasSubject: false) == [
        "message-guid",
        "message-guid_1",
        "message-guid_2",
    ])
}

@Test func messageDeletionIDsIncludeDetachedSubjectPart() {
    #expect(messageDeletionIDs(messageGUID: "message-guid", partCount: 2, hasSubject: true) == [
        "message-guid",
        "message-guid_-1",
        "message-guid_1",
    ])
}
