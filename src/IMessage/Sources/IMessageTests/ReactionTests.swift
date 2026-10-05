@testable import IMessage
import Testing

@Test func tapbackEmojisFallBackWithoutCustomEmojiReactions() {
    let mappings: [(emoji: Character, tapbackID: String)] = [
        ("\u{2764}", "heart"),
        ("\u{2764}\u{fe0f}", "heart"),
        ("👍", "thumbsUp"),
        ("👎", "thumbsDown"),
        ("😂", "ha"),
        ("\u{203c}", "exclamation"),
        ("\u{203c}\u{fe0f}", "exclamation"),
        ("❓", "questionMark"),
    ]

    for mapping in mappings {
        let reaction = Reaction(emoji: mapping.emoji, supportsCustomEmojiReactions: false)
        #expect(reaction?.id == mapping.tapbackID)
    }
}

@Test(arguments: ["❤", "❤️", "👍", "👎", "‼", "‼️", "❓", "😂"] as [Character])
func tapbackEmojiPreservesCustomIdentity(emoji: Character) throws {
    let reaction = try #require(Reaction(emoji: emoji, supportsCustomEmojiReactions: true))
    guard case let .custom(character) = reaction else {
        Issue.record("Expected custom emoji identity to be preserved for add and remove")
        return
    }
    #expect(character == emoji)
    #expect(reaction.idOrEmoji == String(emoji))
}

@Test func distinctEmojiRemainsCustomWhenCustomEmojiReactionsAreSupported() throws {
    guard case let .custom(emoji) = try #require(Reaction(emoji: "😂", supportsCustomEmojiReactions: true)) else {
        Issue.record("Expected 😂 to be sent as a custom emoji reaction rather than HAHA")
        return
    }
    #expect(emoji == "😂")
}

@Test func unsupportedEmojiDoesNotFallBackWithoutCustomEmojiReactions() {
    #expect(Reaction(emoji: "🎉", supportsCustomEmojiReactions: false) == nil)
}

@Test func laughTapbackKeyStillMapsToLaughTapback() throws {
    guard case .laugh = try #require(Reaction(platformSDKReactionKey: "laugh")) else {
        Issue.record("Expected laugh key to map to the laugh Tapback")
        return
    }
}
