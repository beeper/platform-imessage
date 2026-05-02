import Foundation

extension PlatformSDK {
    public enum MessageBehavior: String {
        case silent
        case keepRead = "keep_read"
        case dontNotify = "dont_notify"
    }

    @PlatformSDKJSONObject
    public struct MessageReaction: JSONObjectConvertible {
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
