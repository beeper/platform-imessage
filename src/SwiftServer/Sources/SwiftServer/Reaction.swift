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

    /// The custom action name as exposed by Messages accessibility API.
    /// Custom actions on message elements (with identifier "Sticker") have format:
    /// "Name:<action_name>\nTarget:0x0\nSelector:(null)"
    var customActionName: String {
        switch self {
        case .heart: "Heart"
        case .like: "Thumbs up"
        case .dislike: "Thumbs down"
        case .laugh: "Ha ha!"
        case .emphasize: "Exclamation mark"
        case .question: "Question mark"
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
        // NOTE: This is mapping actual emoji characters into the traditional set of iMessage Tapbacks.
        // This means it's impossible to react with an actual heart emoji character, because it gets mapped to the "iMessage heart".
        // It's possible to choosen between either in actual iMessage.
        //
        // (For robustness, also accept emojified codepoints even without U+FE0F.)
        switch emoji {
        /* ❤️ */ case "\u{2764}", "\u{2764}\u{fe0f}": self = .heart
        /* 👍 */ case "\u{1f44d}": self = .like
        /* 👎 */ case "\u{1f44e}": self = .dislike
        /* 😂 */ case "\u{1f602}": self = .laugh
        /* ‼️ */ case "\u{203c}", "\u{203c}\u{fe0f}": self = .emphasize
        /* ❓ */ case "\u{2753}": self = .question
        default:
            guard #available(macOS 15, *) else {
                return nil
            }
            self = .custom(emoji: emoji)
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
