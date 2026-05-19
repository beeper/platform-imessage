import Foundation

extension PlatformSDK {
    @PlatformSDKJSONObject
    public struct MessageEdit: JSONObjectConvertible {
        public let timestamp: Timestamp?
        public let id: MessageID?
        public let editedTimestamp: Timestamp?
        public let expiresInSeconds: Int?
        public let forwardedCount: Int?
        public let forwardedFrom: JSONObject?
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

    public enum MessageBehavior: String {
        case silent
        case keepRead = "keep_read"
        case dontNotify = "dont_notify"
    }

    @PlatformSDKJSONObject
    public struct MessageReaction: JSONObjectConvertible {
        /// Stable reaction ID, always `${participantID}${reactionKey}`.
        public let id: ID
        public let reactionKey: String
        public let imgURL: String?
        public let participantID: UserID
        public let emoji: Bool?
    }

    public enum MessageSeen: JSONValueConvertible {
        case bool(Bool)
        case timestamp(Timestamp)
        case participants([UserID: ParticipantSeen])

        public var jsonValue: Any {
            switch self {
            case let .bool(value):
                return value
            case let .timestamp(value):
                return value
            case let .participants(value):
                return value.mapValues(\.jsonValue)
            }
        }
    }

    public enum ParticipantSeen: JSONValueConvertible {
        case bool(Bool)
        case timestamp(Timestamp)

        public var jsonValue: Any {
            switch self {
            case let .bool(value):
                return value
            case let .timestamp(value):
                return value
            }
        }
    }

    @PlatformSDKJSONObject
    public struct MessageLink: JSONObjectConvertible {
        public let url: String
        public let originalURL: String?
        public let favicon: String?
        public let img: String?
        public let imgSize: Size?
        public let title: String?
        public let summary: String?
    }

    @PlatformSDKJSONObject
    public struct Tweet: JSONObjectConvertible {
        @PlatformSDKJSONObject
        public struct User: JSONObjectConvertible {
            public let imgURL: String
            public let name: String
            public let username: String
            public let isVerified: Bool?
        }

        public let id: ID
        public let user: User
        public let text: String
        public let timestamp: Timestamp?
        public let url: String?
        public let textAttributes: TextAttributes?
        public let attachments: [Attachment]?
        public let quotedTweet: TweetBox?
    }

    public final class TweetBox: JSONValueConvertible {
        public let tweet: Tweet

        public init(_ tweet: Tweet) {
            self.tweet = tweet
        }

        public var jsonValue: Any {
            tweet.jsonObject
        }
    }

    @PlatformSDKJSONObject
    public struct MessagePreview: JSONObjectConvertible {
        public let id: MessageID
        public let threadID: ThreadID?
        public let text: String?
        public let senderID: UserID?
        public let attachments: [Attachment]?
    }

    @PlatformSDKJSONObject
    public struct MessageButton: JSONObjectConvertible {
        public let label: String
        public let linkURL: String
    }
}
