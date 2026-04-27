import Foundation
import IMessageCore

extension PlatformSDK {
    public struct TextAttributes: JSONObjectConvertible {
        public let entities: [TextEntity]?
        public let heDecode: Bool?

        public init(entities: [TextEntity]? = nil, heDecode: Bool? = nil) {
            self.entities = entities
            self.heDecode = heDecode
        }

        public init(jsonObject: JSONObject) throws {
            entities = try jsonObject.hasValue("entities")
                ? PlatformSDKJSON.objectArray(jsonObject["entities"]).map(TextEntity.init(jsonObject:))
                : nil
            heDecode = jsonObject.bool("heDecode")
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "entities": entities?.map(\.jsonObject),
                "heDecode": heDecode,
            ])
        }
    }

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

        public init(jsonObject: JSONObject) throws {
            from = try PlatformSDKJSON.int(jsonObject["from"]).orThrow(ErrorMessage("Bad TextEntity: missing from"))
            to = try PlatformSDKJSON.int(jsonObject["to"]).orThrow(ErrorMessage("Bad TextEntity: missing to"))
            bold = jsonObject.bool("bold")
            italic = jsonObject.bool("italic")
            underline = jsonObject.bool("underline")
            strikethrough = jsonObject.bool("strikethrough")
            quote = jsonObject.bool("quote")
            spoiler = jsonObject.bool("spoiler")
            code = jsonObject.bool("code")
            pre = jsonObject.bool("pre")
            codeLanguage = jsonObject.string("codeLanguage")
            markdown = jsonObject.string("markdown")
            replaceWith = jsonObject.string("replaceWith")
            replaceWithMedia = try jsonObject.dictionary("replaceWithMedia").map(ReplaceWithMediaEntity.init(jsonObject:))
            link = jsonObject.string("link")
            mentionedUser = jsonObject.dictionary("mentionedUser").map(MentionedUser.init(jsonObject:))
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "from": from,
                "to": to,
                "bold": bold,
                "italic": italic,
                "underline": underline,
                "strikethrough": strikethrough,
                "quote": quote,
                "spoiler": spoiler,
                "code": code,
                "pre": pre,
                "codeLanguage": codeLanguage,
                "markdown": markdown,
                "replaceWith": replaceWith,
                "replaceWithMedia": replaceWithMedia?.jsonObject,
                "link": link,
                "mentionedUser": mentionedUser?.jsonObject,
            ])
        }
    }

    public struct ReplaceWithMediaEntity: JSONObjectConvertible {
        public let mediaType: AttachmentType
        public let srcURL: String
        public let size: Size?
        public let loop: Bool?
        public let rounded: Bool?

        public init(jsonObject: JSONObject) throws {
            mediaType = jsonObject.string("mediaType").flatMap(AttachmentType.init(rawValue:)) ?? .img
            srcURL = try PlatformSDKJSON.requiredString(jsonObject, "srcURL", type: "ReplaceWithMediaEntity")
            size = try jsonObject.dictionary("size").map(Size.init(jsonObject:))
            loop = jsonObject.bool("loop")
            rounded = jsonObject.bool("rounded")
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "mediaType": mediaType.rawValue,
                "srcURL": srcURL,
                "size": size?.jsonObject,
                "loop": loop,
                "rounded": rounded,
            ])
        }
    }

    public struct MentionedUser: JSONObjectConvertible {
        public let username: String?
        public let id: UserID?

        public init(username: String? = nil, id: UserID? = nil) {
            self.username = username
            self.id = id
        }

        public init(jsonObject: JSONObject) {
            username = jsonObject.string("username")
            id = jsonObject.string("id")
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "username": username,
                "id": id,
            ])
        }
    }
}
