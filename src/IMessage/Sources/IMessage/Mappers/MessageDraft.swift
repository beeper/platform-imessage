import PlatformSDK

struct MessageDraft {
    var id: String
    var timestamp: PlatformSDK.Timestamp
    var editedTimestamp: PlatformSDK.Timestamp?
    var senderID: String
    var text: String?
    var textAttributes: PlatformSDK.TextAttributes?
    var textHeading: String?
    var textFooter: String?
    var attachments: [PlatformSDK.Attachment]?
    var tweets: [PlatformSDK.Tweet]?
    var links: [PlatformSDK.MessageLink]?
    var iframeURL: String?
    var reactions: [PlatformSDK.MessageReaction]?
    var seen: PlatformSDK.MessageSeen?
    var isDelivered: Bool?
    var isHidden: Bool?
    var isSender: Bool?
    var isAction: Bool?
    var isDeleted: Bool?
    var isErrored: Bool?
    var parseTemplate: Bool?
    var linkedMessageID: String?
    var action: PlatformSDK.MessageAction?
    var behavior: PlatformSDK.MessageBehavior?
    var threadID: String?
    var sortKey: Any?
    var cursor: String?
    var extra = JSONObject()

    func message() -> PlatformSDK.Message {
        PlatformSDK.Message(
            id: id,
            timestamp: timestamp,
            editedTimestamp: editedTimestamp,
            senderID: senderID,
            text: text,
            textAttributes: textAttributes,
            textHeading: textHeading,
            textFooter: textFooter,
            attachments: attachments,
            tweets: tweets,
            links: links,
            iframeURL: iframeURL,
            reactions: reactions,
            seen: seen,
            isDelivered: isDelivered,
            isHidden: isHidden,
            isSender: isSender,
            isAction: isAction,
            isDeleted: isDeleted,
            isErrored: isErrored,
            parseTemplate: parseTemplate,
            linkedMessageID: linkedMessageID,
            action: action,
            behavior: behavior,
            threadID: threadID,
            sortKey: sortKey,
            cursor: cursor,
            extra: extra.isEmpty ? nil : extra
        )
    }
}

struct MessagePatch {
    var text: String?
    var textHeading: String?
    var textFooter: String?
    var attachments: [PlatformSDK.Attachment]?
    var tweets: [PlatformSDK.Tweet]?
    var links: [PlatformSDK.MessageLink]?
    var iframeURL: String?
    var linkedMessageID: String?
    var extra: JSONObject?

    func apply(to message: inout MessageDraft) {
        if let text {
            message.text = text
        }
        if let textHeading {
            message.textHeading = textHeading
        }
        if let textFooter {
            message.textFooter = textFooter
        }
        if let attachments {
            message.attachments = attachments
        }
        if let tweets {
            message.tweets = tweets
        }
        if let links {
            message.links = links
        }
        if let iframeURL {
            message.iframeURL = iframeURL
        }
        if let linkedMessageID {
            message.linkedMessageID = linkedMessageID
        }
        if let extra {
            for (key, value) in extra {
                message.extra[key] = value
            }
        }
    }
}
