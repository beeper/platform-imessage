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

    // @unchecked because `Any`-typed fields (mutedUntil/extra) can't be
    // compiler-verified; they only ever hold immutable JSON-bridge values.
    @PlatformSDKJSONObject
    public struct Thread: JSONObjectConvertible, @unchecked Sendable {
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
        public let unreadCount: Int?
        public let isMarkedUnread: Bool?
        public let lastReadMessageSortKey: Timestamp?
        public let isLowPriority: Bool?
    }
}
