import Foundation
@testable import IMessage
import Testing

private let fixtureMessageGUID = "08E8CAE0-FA6F-408D-8E22-FB0712D116D9"

@Test func messageGUIDStripsPublicPartSuffix() {
    #expect(messageGUID(fromID: fixtureMessageGUID) == fixtureMessageGUID)
    #expect(messageGUID(fromID: "\(fixtureMessageGUID)_1") == fixtureMessageGUID)
}

@Test func messageIDPartsExtractsGUIDAndPartIndex() {
    let bare = messageIDParts(fromID: fixtureMessageGUID)
    #expect(bare.messageGUID == fixtureMessageGUID)
    #expect(bare.partIndex == nil)

    let part = messageIDParts(fromID: "\(fixtureMessageGUID)_2")
    #expect(part.messageGUID == fixtureMessageGUID)
    #expect(part.partIndex == 2)

    let nonNumeric = messageIDParts(fromID: "\(fixtureMessageGUID)_x")
    #expect(nonNumeric.messageGUID == fixtureMessageGUID)
    #expect(nonNumeric.partIndex == nil)

    let trailing = messageIDParts(fromID: "\(fixtureMessageGUID)_")
    #expect(trailing.messageGUID == fixtureMessageGUID)
    #expect(trailing.partIndex == nil)
}

@Test func threadIDGroupDetectionDoesNotRequireRoomName() {
    #expect(threadIsGroup(threadID: "iMessage;+;untitled-group", roomName: nil))
    #expect(threadIsGroup(threadID: "SMS;+;untitled-group", roomName: ""))
    #expect(threadIsGroup(threadID: "iMessage;-;alice@example.com", roomName: "Alice and Bob"))
    #expect(!threadIsGroup(threadID: "iMessage;-;alice@example.com", roomName: nil))
}

@Test func messagesDeepLinkAllowsPartAddressedMessageGUID() throws {
    let items = try queryItems(for: MessagesDeepLink.message(guid: fixtureMessageGUID, partIndex: 1, overlay: false).url())

    #expect(items["message-guid"] == "p:1/\(fixtureMessageGUID)")
    #expect(items["overlay"] == nil)

    let overlayItems = try queryItems(for: MessagesDeepLink.message(guid: fixtureMessageGUID, partIndex: 1, overlay: true).url())

    #expect(overlayItems["message-guid"] == "p:1/\(fixtureMessageGUID)")
    #expect(overlayItems["overlay"] == "1")
}

@Test func messagesDeepLinkAllowsNegativePartIndex() throws {
    let items = try queryItems(for: MessagesDeepLink.message(guid: fixtureMessageGUID, partIndex: -1, overlay: nil).url())

    #expect(items["message-guid"] == "p:-1/\(fixtureMessageGUID)")
}

@Test func messagesDeepLinkWithoutPartIndexUsesBareGUID() throws {
    let items = try queryItems(for: MessagesDeepLink.message(guid: fixtureMessageGUID, partIndex: nil, overlay: nil).url())

    #expect(items["message-guid"] == fixtureMessageGUID)
    #expect(items["message-guid"]?.hasPrefix("p:") == false)
    #expect(items["overlay"] == nil)
}

@Test func messagesDeepLinkRejectsGUIDContainingUnderscore() {
    #expect(throws: (any Error).self) {
        try MessagesDeepLink.message(guid: "\(fixtureMessageGUID)_1", partIndex: nil, overlay: nil).url()
    }
    #expect(throws: (any Error).self) {
        try MessagesDeepLink.message(guid: "\(fixtureMessageGUID)_1", partIndex: 1, overlay: nil).url()
    }
}

private func queryItems(for url: URL) throws -> [String: String] {
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
}
