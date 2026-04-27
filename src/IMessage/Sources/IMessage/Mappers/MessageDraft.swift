import Foundation

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
    var original: String?

    init(
        id: String,
        timestamp: PlatformSDK.Timestamp,
        editedTimestamp: PlatformSDK.Timestamp? = nil,
        senderID: String,
        text: String? = nil,
        textAttributes: PlatformSDK.TextAttributes? = nil,
        textHeading: String? = nil,
        textFooter: String? = nil,
        attachments: [PlatformSDK.Attachment]? = nil,
        tweets: [PlatformSDK.Tweet]? = nil,
        links: [PlatformSDK.MessageLink]? = nil,
        iframeURL: String? = nil,
        reactions: [PlatformSDK.MessageReaction]? = nil,
        seen: PlatformSDK.MessageSeen? = nil,
        isDelivered: Bool? = nil,
        isHidden: Bool? = nil,
        isSender: Bool? = nil,
        isAction: Bool? = nil,
        isDeleted: Bool? = nil,
        isErrored: Bool? = nil,
        parseTemplate: Bool? = nil,
        linkedMessageID: String? = nil,
        action: PlatformSDK.MessageAction? = nil,
        behavior: PlatformSDK.MessageBehavior? = nil,
        threadID: String? = nil,
        sortKey: Any? = nil,
        cursor: String? = nil,
        extra: JSONObject = [:],
        original: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.editedTimestamp = editedTimestamp
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
        self.linkedMessageID = linkedMessageID
        self.action = action
        self.behavior = behavior
        self.threadID = threadID
        self.sortKey = sortKey
        self.cursor = cursor
        self.extra = extra
        self.original = original
    }

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
            extra: extra.isEmpty ? nil : extra,
            original: original
        )
    }
}

struct MessagePatch {
    var textHeading: String?
    var textFooter: String?
    var attachments: [PlatformSDK.Attachment]?
    var tweets: [PlatformSDK.Tweet]?
    var links: [PlatformSDK.MessageLink]?
    var iframeURL: String?
    var linkedMessageID: String?

    init(
        textHeading: String? = nil,
        textFooter: String? = nil,
        attachments: [PlatformSDK.Attachment]? = nil,
        tweets: [PlatformSDK.Tweet]? = nil,
        links: [PlatformSDK.MessageLink]? = nil,
        iframeURL: String? = nil,
        linkedMessageID: String? = nil
    ) {
        self.textHeading = textHeading
        self.textFooter = textFooter
        self.attachments = attachments
        self.tweets = tweets
        self.links = links
        self.iframeURL = iframeURL
        self.linkedMessageID = linkedMessageID
    }

    func apply(to message: inout MessageDraft) {
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
    }
}
