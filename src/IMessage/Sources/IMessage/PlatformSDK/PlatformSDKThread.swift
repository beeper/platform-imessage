import Foundation
import IMessageCore

extension PlatformSDK {
    public enum ThreadType: String {
        case single
        case group
        case channel
        case broadcast
    }

    public struct PartialLastMessage: JSONObjectConvertible {
        public let id: MessageID
        public let text: String?
        public let isSender: Bool?
        public let senderID: UserID?
        public let attachments: [Attachment]?

        public init(jsonObject: JSONObject) throws {
            id = try PlatformSDKJSON.requiredString(jsonObject, "id", type: "PartialLastMessage")
            text = jsonObject.string("text")
            isSender = jsonObject.bool("isSender")
            senderID = jsonObject.string("senderID")
            attachments = try jsonObject.hasValue("attachments")
                ? PlatformSDKJSON.objectArray(jsonObject["attachments"]).map(Attachment.init(jsonObject:))
                : nil
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "id": id,
                "text": text,
                "isSender": isSender,
                "senderID": senderID,
                "attachments": attachments?.map(\.jsonObject),
            ])
        }
    }

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
        public let original: String?
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

        public init(jsonObject: JSONObject) throws {
            id = try PlatformSDKJSON.requiredString(jsonObject, "id", type: "Thread")
            folderName = jsonObject.string("folderName")
            title = jsonObject.string("title")
            let unreadCount = PlatformSDKJSON.int(jsonObject["unreadCount"])
            self.unreadCount = unreadCount
            isMarkedUnread = jsonObject.bool("isMarkedUnread")
            isUnread = jsonObject.bool("isUnread") ?? isMarkedUnread ?? ((unreadCount ?? 0) > 0)
            lastReadMessageID = jsonObject.string("lastReadMessageID")
            isReadOnly = try PlatformSDKJSON.requiredBool(jsonObject, "isReadOnly", type: "Thread")
            isArchived = jsonObject.bool("isArchived")
            isPinned = jsonObject.bool("isPinned")
            mutedUntil = jsonObject["mutedUntil"]
            type = jsonObject.string("type").flatMap(ThreadType.init(rawValue:)) ?? .single
            timestamp = PlatformSDKJSON.timestamp(jsonObject["timestamp"])
            imgURL = jsonObject.string("imgURL")
            createdAt = PlatformSDKJSON.timestamp(jsonObject["createdAt"])
            description = jsonObject.string("description")
            partialLastMessage = try jsonObject.dictionary("partialLastMessage").map(PartialLastMessage.init(jsonObject:))
            messageExpirySeconds = PlatformSDKJSON.int(jsonObject["messageExpirySeconds"])
            messages = try Paginated<Message>(
                jsonObject: jsonObject.dictionary("messages") ?? ["items": [], "hasMore": false],
                item: Message.init(jsonObject:)
            )
            participants = try Paginated<Participant>(
                jsonObject: jsonObject.dictionary("participants") ?? ["items": [], "hasMore": false],
                item: Participant.init(jsonObject:)
            )
            extra = jsonObject["extra"]
            original = jsonObject.string("_original")
            lastReadMessageSortKey = PlatformSDKJSON.timestamp(jsonObject["lastReadMessageSortKey"])
            isLowPriority = jsonObject.bool("isLowPriority")
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "id": id,
                "folderName": folderName,
                "title": title,
                "isUnread": isUnread,
                "lastReadMessageID": lastReadMessageID,
                "isReadOnly": isReadOnly,
                "isArchived": isArchived,
                "isPinned": isPinned,
                "mutedUntil": mutedUntil,
                "type": type.rawValue,
                "timestamp": timestamp,
                "imgURL": imgURL,
                "createdAt": createdAt,
                "description": description,
                "partialLastMessage": partialLastMessage?.jsonObject,
                "messageExpirySeconds": messageExpirySeconds,
                "messages": messages.jsonObject,
                "participants": participants.jsonObject,
                "extra": extra,
                "_original": original,
                "unreadCount": unreadCount,
                "isMarkedUnread": isMarkedUnread,
                "lastReadMessageSortKey": lastReadMessageSortKey,
                "isLowPriority": isLowPriority,
            ])
        }
    }
}
