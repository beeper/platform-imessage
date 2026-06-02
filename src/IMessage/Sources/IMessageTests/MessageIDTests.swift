import Foundation
@testable import IMessage
import Testing

private let fixtureMessageGUID = "08E8CAE0-FA6F-408D-8E22-FB0712D116D9"

@Test func messageGUIDStripsPublicPartSuffix() {
    #expect(messageGUID(fromID: fixtureMessageGUID) == fixtureMessageGUID)
    #expect(messageGUID(fromID: "\(fixtureMessageGUID)_1") == fixtureMessageGUID)
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

private func queryItems(for url: URL) throws -> [String: String] {
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
}
