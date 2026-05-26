@testable import IMessage
import Testing

@Test func emojiReactionDoesNotMapToTapback() throws {
    guard #available(macOS 15, *) else {
        #expect(Reaction(emoji: "😂") == nil)
        return
    }

    guard case let .custom(emoji) = try #require(Reaction(emoji: "😂")) else {
        Issue.record("Expected 😂 to be sent as a custom emoji reaction")
        return
    }
    #expect(emoji == "😂")
}

@Test func laughTapbackKeyStillMapsToLaughTapback() throws {
    guard case .laugh = try #require(Reaction(platformSDKReactionKey: "laugh")) else {
        Issue.record("Expected laugh key to map to the laugh Tapback")
        return
    }
}
