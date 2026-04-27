import Foundation

extension PlatformSDK {
    public enum ThreadType: String {
        case single
        case group
        case channel
        case broadcast
    }

    @PlatformSDKJSONObject
    public struct PartialLastMessage: JSONObjectConvertible {
        public let id: MessageID
        public let text: String?
        public let isSender: Bool?
        public let senderID: UserID?
        public let attachments: [Attachment]?

    }

    @PlatformSDKJSONObject
    public struct Thread: JSONObjectConvertible {
        public let id: ThreadID
        public let folderName: String?
        public let title: String?
        public let isUnread: Bool
        public let lastReadMessageID: MessageID?
        public let isReadOnly: Bool
        public let isArchived: Bool?
        public let isPinned: Bool?
        public let mutedUntil: Any?
        public let type: ThreadType
        public let timestamp: Timestamp?
        public let imgURL: String?
        public let createdAt: Timestamp?
        public let description: String?
        public let partialLastMessage: PartialLastMessage?
        public let messageExpirySeconds: Int?
        public let messages: Paginated<Message>
        public let participants: Paginated<Participant>
        public let extra: Any?
        @PlatformSDKJSONKey("_original") public let original: String?
        public let unreadCount: Int?
        public let isMarkedUnread: Bool?
        public let lastReadMessageSortKey: Timestamp?
        public let isLowPriority: Bool?

        public init(
            id: ThreadID,
            folderName: String? = nil,
            title: String? = nil,
            isUnread: Bool,
            lastReadMessageID: MessageID? = nil,
            isReadOnly: Bool,
            isArchived: Bool? = nil,
            isPinned: Bool? = nil,
            mutedUntil: Any? = nil,
            type: ThreadType,
            timestamp: Timestamp? = nil,
            imgURL: String? = nil,
            createdAt: Timestamp? = nil,
            description: String? = nil,
            partialLastMessage: PartialLastMessage? = nil,
            messageExpirySeconds: Int? = nil,
            messages: Paginated<Message>,
            participants: Paginated<Participant>,
            extra: Any? = nil,
            original: String? = nil,
            unreadCount: Int? = nil,
            isMarkedUnread: Bool? = nil,
            lastReadMessageSortKey: Timestamp? = nil,
            isLowPriority: Bool? = nil
        ) {
            self.id = id
            self.folderName = folderName
            self.title = title
            self.isUnread = isUnread
            self.lastReadMessageID = lastReadMessageID
            self.isReadOnly = isReadOnly
            self.isArchived = isArchived
            self.isPinned = isPinned
            self.mutedUntil = mutedUntil
            self.type = type
            self.timestamp = timestamp
            self.imgURL = imgURL
            self.createdAt = createdAt
            self.description = description
            self.partialLastMessage = partialLastMessage
            self.messageExpirySeconds = messageExpirySeconds
            self.messages = messages
            self.participants = participants
            self.extra = extra
            self.original = original
            self.unreadCount = unreadCount
            self.isMarkedUnread = isMarkedUnread
            self.lastReadMessageSortKey = lastReadMessageSortKey
            self.isLowPriority = isLowPriority
        }

    }
}
