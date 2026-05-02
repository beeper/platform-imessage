import Foundation

extension PlatformSDK {
    @PlatformSDKJSONObject
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
    }
}
