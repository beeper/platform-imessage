import Foundation
import IMessageCore

extension PlatformSDK {
    public enum MessageBehavior: String {
        case silent
        case keepRead = "keep_read"
        case dontNotify = "dont_notify"
    }

    public struct MessageReaction: JSONObjectConvertible {
        public let id: ID
        public let reactionKey: String
        public let imgURL: String?
        public let participantID: UserID
        public let emoji: Bool?

        public init(id: ID, reactionKey: String, imgURL: String? = nil, participantID: UserID, emoji: Bool? = nil) {
            self.id = id
            self.reactionKey = reactionKey
            self.imgURL = imgURL
            self.participantID = participantID
            self.emoji = emoji
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "id": id,
                "reactionKey": reactionKey,
                "imgURL": imgURL,
                "participantID": participantID,
                "emoji": emoji,
            ])
        }
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

    public struct MessageLink: JSONObjectConvertible {
        public let url: String
        public let originalURL: String?
        public let favicon: String?
        public let img: String?
        public let imgSize: Size?
        public let title: String
        public let summary: String?

        public init(
            url: String,
            originalURL: String? = nil,
            favicon: String? = nil,
            img: String? = nil,
            imgSize: Size? = nil,
            title: String,
            summary: String? = nil
        ) {
            self.url = url
            self.originalURL = originalURL
            self.favicon = favicon
            self.img = img
            self.imgSize = imgSize
            self.title = title
            self.summary = summary
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "url": url,
                "originalURL": originalURL,
                "favicon": favicon,
                "img": img,
                "imgSize": imgSize?.jsonObject,
                "title": title,
                "summary": summary,
            ])
        }
    }

    public struct Tweet: JSONObjectConvertible {
        public struct User: JSONObjectConvertible {
            public let imgURL: String
            public let name: String
            public let username: String
            public let isVerified: Bool?

            public init(imgURL: String, name: String, username: String, isVerified: Bool? = nil) {
                self.imgURL = imgURL
                self.name = name
                self.username = username
                self.isVerified = isVerified
            }

            public var jsonObject: JSONObject {
                compactDictionary([
                    "imgURL": imgURL,
                    "name": name,
                    "username": username,
                    "isVerified": isVerified,
                ])
            }
        }

        public let id: ID
        public let user: User
        public let text: String
        public let timestamp: Timestamp?
        public let url: String?
        public let textAttributes: TextAttributes?
        public let attachments: [Attachment]?
        public let quotedTweet: TweetBox?

        public init(
            id: ID,
            user: User,
            text: String,
            timestamp: Timestamp? = nil,
            url: String? = nil,
            textAttributes: TextAttributes? = nil,
            attachments: [Attachment]? = nil,
            quotedTweet: TweetBox? = nil
        ) {
            self.id = id
            self.user = user
            self.text = text
            self.timestamp = timestamp
            self.url = url
            self.textAttributes = textAttributes
            self.attachments = attachments
            self.quotedTweet = quotedTweet
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "id": id,
                "user": user.jsonObject,
                "text": text,
                "timestamp": timestamp,
                "url": url,
                "textAttributes": textAttributes?.jsonObject,
                "attachments": attachments?.map(\.jsonObject),
                "quotedTweet": quotedTweet?.tweet.jsonObject,
            ])
        }
    }

    public final class TweetBox {
        public let tweet: Tweet

        public init(_ tweet: Tweet) {
            self.tweet = tweet
        }
    }

    public struct MessagePreview: JSONObjectConvertible {
        public let id: MessageID
        public let threadID: ThreadID?
        public let text: String?
        public let senderID: UserID?
        public let attachments: [Attachment]?

        public var jsonObject: JSONObject {
            compactDictionary([
                "id": id,
                "threadID": threadID,
                "text": text,
                "senderID": senderID,
                "attachments": attachments?.map(\.jsonObject),
            ])
        }
    }

    public struct MessageButton: JSONObjectConvertible {
        public let label: String
        public let linkURL: String

        public var jsonObject: JSONObject {
            [
                "label": label,
                "linkURL": linkURL,
            ]
        }
    }
}
