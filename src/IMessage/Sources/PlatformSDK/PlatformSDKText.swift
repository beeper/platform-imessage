import Foundation

extension PlatformSDK {
    @PlatformSDKJSONObject
    public struct TextAttributes: JSONObjectConvertible {
        public let entities: [TextEntity]?
        public let heDecode: Bool?
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
    }
}
