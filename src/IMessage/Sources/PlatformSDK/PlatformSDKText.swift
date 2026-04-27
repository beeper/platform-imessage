import Foundation

extension PlatformSDK {
    @PlatformSDKJSONObject
    public struct TextAttributes: JSONObjectConvertible {
        public let entities: [TextEntity]?
        public let heDecode: Bool?

        public init(entities: [TextEntity]? = nil, heDecode: Bool? = nil) {
            self.entities = entities
            self.heDecode = heDecode
        }

    }

    @PlatformSDKJSONObject
    public struct TextEntity: JSONObjectConvertible {
        public let from: Int
        public let to: Int
        public let bold: Bool?
        public let italic: Bool?
        public let underline: Bool?
        public let strikethrough: Bool?
        public let quote: Bool?
        public let spoiler: Bool?
        public let code: Bool?
        public let pre: Bool?
        public let codeLanguage: String?
        public let markdown: String?
        public let replaceWith: String?
        public let replaceWithMedia: ReplaceWithMediaEntity?
        public let link: String?
        public let mentionedUser: MentionedUser?

        public init(
            from: Int,
            to: Int,
            bold: Bool? = nil,
            italic: Bool? = nil,
            underline: Bool? = nil,
            strikethrough: Bool? = nil,
            quote: Bool? = nil,
            spoiler: Bool? = nil,
            code: Bool? = nil,
            pre: Bool? = nil,
            codeLanguage: String? = nil,
            markdown: String? = nil,
            replaceWith: String? = nil,
            replaceWithMedia: ReplaceWithMediaEntity? = nil,
            link: String? = nil,
            mentionedUser: MentionedUser? = nil
        ) {
            self.from = from
            self.to = to
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.strikethrough = strikethrough
            self.quote = quote
            self.spoiler = spoiler
            self.code = code
            self.pre = pre
            self.codeLanguage = codeLanguage
            self.markdown = markdown
            self.replaceWith = replaceWith
            self.replaceWithMedia = replaceWithMedia
            self.link = link
            self.mentionedUser = mentionedUser
        }

    }

    @PlatformSDKJSONObject
    public struct ReplaceWithMediaEntity: JSONObjectConvertible {
        public let mediaType: AttachmentType
        public let srcURL: String
        public let size: Size?
        public let loop: Bool?
        public let rounded: Bool?

    }

    @PlatformSDKJSONObject
    public struct MentionedUser: JSONObjectConvertible {
        public let username: String?
        public let id: UserID?

        public init(username: String? = nil, id: UserID? = nil) {
            self.username = username
            self.id = id
        }

    }
}
