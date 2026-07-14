enum Reaction {
    case heart
    case like
    case dislike
    case laugh
    case emphasize
    case question
    case custom(emoji: Character)

    /// returns nil for custom emojis
    var index: Int? {
        switch self {
        case .heart: 0
        case .like: 1
        case .dislike: 2
        case .laugh: 3
        case .emphasize: 4
        case .question: 5
        default: nil
        }
    }

    /// (sequoia and up) returns nil for custom emojis
    var id: String? {
        switch self {
        case .heart: "heart"
        case .like: "thumbsUp"
        case .dislike: "thumbsDown"
        case .laugh: "ha"
        case .emphasize: "exclamation"
        case .question: "questionMark"
        default: nil
        }
    }

    var idOrEmoji: String {
        switch self {
        case let .custom(emoji): String(emoji)
        default: id!
        }
    }

    var directActionTitle: String {
        switch self {
        case .heart: LocalizedStrings.reactionHeart
        case .like: LocalizedStrings.reactionThumbsUp
        case .dislike: LocalizedStrings.reactionThumbsDown
        case .laugh: LocalizedStrings.reactionHa
        case .emphasize: LocalizedStrings.reactionExclamation
        case .question: LocalizedStrings.reactionQuestionMark
        case let .custom(emoji): String(emoji)
        }
    }

    /// Creates a reaction from a reaction key (as vended to clients via the object keys in `PlatformInfo.reactions`).
    ///
    /// These are only effectively used when running under macOS Sonoma and earlier, because Sequoia introduces
    /// support for arbitrary emojis. This results in `canReactWithAllEmojis` being set to `true` in the platform info.
    init?(platformSDKReactionKey key: String) {
        switch key {
        case "heart": self = .heart
        case "like": self = .like
        case "dislike": self = .dislike
        case "laugh": self = .laugh
        case "emphasize": self = .emphasize
        case "question": self = .question
        default: return nil
        }
    }

    /// Creates a reaction from an arbitrary emoji character.
    ///
    /// Support for arbitrary emojis was added in macOS Sequoia.
    init?(emoji: Character) {
        self.init(emoji: emoji, supportsCustomEmojiReactions: isSequoiaOrUp)
    }

    init?(emoji: Character, supportsCustomEmojiReactions: Bool) {
        if supportsCustomEmojiReactions {
            self = .custom(emoji: emoji)
            return
        }

        // Fall back to the equivalent traditional Tapback on macOS versions
        // that cannot send custom emoji reactions.
        switch emoji {
        /* ❤️ */ case "\u{2764}", "\u{2764}\u{fe0f}": self = .heart
        /* 👍 */ case "\u{1f44d}": self = .like
        /* 👎 */ case "\u{1f44e}": self = .dislike
        /* 😂 */ case "\u{1f602}": self = .laugh
        /* ‼️ */ case "\u{203c}", "\u{203c}\u{fe0f}": self = .emphasize
        /* ❓ */ case "\u{2753}": self = .question
        default: return nil
        }
    }
}

enum EmojiSkinTone: String, CaseIterable, Hashable {
    case light = "\u{1f3fb}"
    case mediumLight = "\u{1f3fc}"
    case medium = "\u{1f3fd}"
    case mediumDark = "\u{1f3fe}"
    case dark = "\u{1f3ff}"
}

extension String {
    var withoutSkinToneModifiers: String {
        var stripped = self
        for skinTone in EmojiSkinTone.allCases {
            stripped = stripped.replacingOccurrences(of: skinTone.rawValue, with: "")
        }
        return stripped
    }
}
