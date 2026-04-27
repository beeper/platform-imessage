import Foundation
import IMessageCore

extension PlatformSDK {
    public struct Message: JSONObjectConvertible {
        public let id: MessageID
        public let timestamp: Timestamp
        public let editedTimestamp: Timestamp?
        public let expiresInSeconds: Int?
        public let forwardedCount: Int?
        public let forwardedFrom: JSONObject?
        public let senderID: UserID
        public let text: String?
        public let textAttributes: TextAttributes?
        public let textHeading: String?
        public let textFooter: String?
        public let attachments: [Attachment]?
        public let tweets: [Tweet]?
        public let links: [MessageLink]?
        public let iframeURL: String?
        public let reactions: [MessageReaction]?
        public let seen: MessageSeen?
        public let isDelivered: Bool?
        public let isHidden: Bool?
        public let isSender: Bool?
        public let isAction: Bool?
        public let isDeleted: Bool?
        public let isErrored: Bool?
        public let parseTemplate: Bool?
        public let linkedMessageThreadID: ThreadID?
        public let linkedMessageID: MessageID?
        public let linkedMessage: MessagePreview?
        public let action: MessageAction?
        public let buttons: [MessageButton]?
        public let behavior: MessageBehavior?
        public let accountID: String?
        public let threadID: ThreadID?
        public let sortKey: Any?
        public let cursor: String?
        public let extra: Any?
        public let original: String?

        public init(
            id: MessageID,
            timestamp: Timestamp,
            editedTimestamp: Timestamp? = nil,
            expiresInSeconds: Int? = nil,
            forwardedCount: Int? = nil,
            forwardedFrom: JSONObject? = nil,
            senderID: UserID,
            text: String? = nil,
            textAttributes: TextAttributes? = nil,
            textHeading: String? = nil,
            textFooter: String? = nil,
            attachments: [Attachment]? = nil,
            tweets: [Tweet]? = nil,
            links: [MessageLink]? = nil,
            iframeURL: String? = nil,
            reactions: [MessageReaction]? = nil,
            seen: MessageSeen? = nil,
            isDelivered: Bool? = nil,
            isHidden: Bool? = nil,
            isSender: Bool? = nil,
            isAction: Bool? = nil,
            isDeleted: Bool? = nil,
            isErrored: Bool? = nil,
            parseTemplate: Bool? = nil,
            linkedMessageThreadID: ThreadID? = nil,
            linkedMessageID: MessageID? = nil,
            linkedMessage: MessagePreview? = nil,
            action: MessageAction? = nil,
            buttons: [MessageButton]? = nil,
            behavior: MessageBehavior? = nil,
            accountID: String? = nil,
            threadID: ThreadID? = nil,
            sortKey: Any? = nil,
            cursor: String? = nil,
            extra: Any? = nil,
            original: String? = nil
        ) {
            self.id = id
            self.timestamp = timestamp
            self.editedTimestamp = editedTimestamp
            self.expiresInSeconds = expiresInSeconds
            self.forwardedCount = forwardedCount
            self.forwardedFrom = forwardedFrom
            self.senderID = senderID
            self.text = text
            self.textAttributes = textAttributes
            self.textHeading = textHeading
            self.textFooter = textFooter
            self.attachments = attachments
            self.tweets = tweets
            self.links = links
            self.iframeURL = iframeURL
            self.reactions = reactions
            self.seen = seen
            self.isDelivered = isDelivered
            self.isHidden = isHidden
            self.isSender = isSender
            self.isAction = isAction
            self.isDeleted = isDeleted
            self.isErrored = isErrored
            self.parseTemplate = parseTemplate
            self.linkedMessageThreadID = linkedMessageThreadID
            self.linkedMessageID = linkedMessageID
            self.linkedMessage = linkedMessage
            self.action = action
            self.buttons = buttons
            self.behavior = behavior
            self.accountID = accountID
            self.threadID = threadID
            self.sortKey = sortKey
            self.cursor = cursor
            self.extra = extra
            self.original = original
        }

        public init(jsonObject: JSONObject) throws {
            id = try PlatformSDKJSON.requiredString(jsonObject, "id", type: "Message")
            timestamp = try PlatformSDKJSON.requiredTimestamp(jsonObject, "timestamp", type: "Message")
            editedTimestamp = PlatformSDKJSON.timestamp(jsonObject["editedTimestamp"])
            expiresInSeconds = PlatformSDKJSON.int(jsonObject["expiresInSeconds"])
            forwardedCount = PlatformSDKJSON.int(jsonObject["forwardedCount"])
            forwardedFrom = jsonObject.dictionary("forwardedFrom")
            senderID = try PlatformSDKJSON.requiredString(jsonObject, "senderID", type: "Message")
            text = jsonObject.string("text")
            textAttributes = try jsonObject.dictionary("textAttributes").map(TextAttributes.init(jsonObject:))
            textHeading = jsonObject.string("textHeading")
            textFooter = jsonObject.string("textFooter")
            attachments = try jsonObject.hasValue("attachments")
                ? PlatformSDKJSON.objectArray(jsonObject["attachments"]).map(Attachment.init(jsonObject:))
                : nil
            tweets = try jsonObject.hasValue("tweets")
                ? PlatformSDKJSON.objectArray(jsonObject["tweets"]).map(Tweet.init(jsonObject:))
                : nil
            links = try jsonObject.hasValue("links")
                ? PlatformSDKJSON.objectArray(jsonObject["links"]).map(MessageLink.init(jsonObject:))
                : nil
            iframeURL = jsonObject.string("iframeURL")
            reactions = try jsonObject.hasValue("reactions")
                ? PlatformSDKJSON.objectArray(jsonObject["reactions"]).map(MessageReaction.init(jsonObject:))
                : nil
            seen = try jsonObject["seen"].map(MessageSeen.init(jsonValue:))
            isDelivered = jsonObject.bool("isDelivered")
            isHidden = jsonObject.bool("isHidden")
            isSender = jsonObject.bool("isSender")
            isAction = jsonObject.bool("isAction")
            isDeleted = jsonObject.bool("isDeleted")
            isErrored = jsonObject.bool("isErrored")
            parseTemplate = jsonObject.bool("parseTemplate")
            linkedMessageThreadID = jsonObject.string("linkedMessageThreadID")
            linkedMessageID = jsonObject.string("linkedMessageID")
            linkedMessage = try jsonObject.dictionary("linkedMessage").map(MessagePreview.init(jsonObject:))
            action = try jsonObject.dictionary("action").map(MessageAction.init(jsonObject:))
            buttons = try jsonObject.hasValue("buttons")
                ? PlatformSDKJSON.objectArray(jsonObject["buttons"]).map(MessageButton.init(jsonObject:))
                : nil
            behavior = jsonObject.string("behavior").flatMap(MessageBehavior.init(rawValue:))
            accountID = jsonObject.string("accountID")
            threadID = jsonObject.string("threadID")
            sortKey = jsonObject["sortKey"]
            cursor = jsonObject.string("cursor")
            extra = jsonObject["extra"]
            original = jsonObject.string("_original")
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "id": id,
                "timestamp": timestamp,
                "editedTimestamp": editedTimestamp,
                "expiresInSeconds": expiresInSeconds,
                "forwardedCount": forwardedCount,
                "forwardedFrom": forwardedFrom,
                "senderID": senderID,
                "text": text,
                "textAttributes": textAttributes?.jsonObject,
                "textHeading": textHeading,
                "textFooter": textFooter,
                "attachments": attachments?.map(\.jsonObject),
                "tweets": tweets?.map(\.jsonObject),
                "links": links?.map(\.jsonObject),
                "iframeURL": iframeURL,
                "reactions": reactions?.map(\.jsonObject),
                "seen": seen?.jsonValue,
                "isDelivered": isDelivered,
                "isHidden": isHidden,
                "isSender": isSender,
                "isAction": isAction,
                "isDeleted": isDeleted,
                "isErrored": isErrored,
                "parseTemplate": parseTemplate,
                "linkedMessageThreadID": linkedMessageThreadID,
                "linkedMessageID": linkedMessageID,
                "linkedMessage": linkedMessage?.jsonObject,
                "action": action?.jsonObject,
                "buttons": buttons?.map(\.jsonObject),
                "behavior": behavior?.rawValue,
                "accountID": accountID,
                "threadID": threadID,
                "sortKey": sortKey,
                "cursor": cursor,
                "extra": extra,
                "_original": original,
            ])
        }
    }
}
