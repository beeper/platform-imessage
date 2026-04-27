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

        public init(jsonObject: JSONObject) throws {
            id = try PlatformSDKJSON.requiredString(jsonObject, "id", type: "MessageReaction")
            reactionKey = try PlatformSDKJSON.requiredString(jsonObject, "reactionKey", type: "MessageReaction")
            imgURL = jsonObject.string("imgURL")
            participantID = try PlatformSDKJSON.requiredString(jsonObject, "participantID", type: "MessageReaction")
            emoji = jsonObject.bool("emoji")
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

        public init(jsonValue: Any) throws {
            if let value = jsonValue as? Bool {
                self = .bool(value)
            } else if let timestamp = PlatformSDKJSON.timestamp(jsonValue) {
                self = .timestamp(timestamp)
            } else if let object = jsonValue as? JSONObject {
                self = .participants(Dictionary(uniqueKeysWithValues: object.compactMap { key, value in
                    try? (key, ParticipantSeen(jsonValue: value))
                }))
            } else {
                throw ErrorMessage("Bad MessageSeen")
            }
        }

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

        init(jsonValue: Any) throws {
            if let value = jsonValue as? Bool {
                self = .bool(value)
            } else if let timestamp = PlatformSDKJSON.timestamp(jsonValue) {
                self = .timestamp(timestamp)
            } else {
                throw ErrorMessage("Bad ParticipantSeen")
            }
        }

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

        public init(jsonObject: JSONObject) throws {
            url = try PlatformSDKJSON.requiredString(jsonObject, "url", type: "MessageLink")
            originalURL = jsonObject.string("originalURL")
            favicon = jsonObject.string("favicon")
            img = jsonObject.string("img")
            imgSize = try jsonObject.dictionary("imgSize").map(Size.init(jsonObject:))
            title = jsonObject.string("title") ?? ""
            summary = jsonObject.string("summary")
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

            public init(jsonObject: JSONObject) throws {
                imgURL = try PlatformSDKJSON.requiredString(jsonObject, "imgURL", type: "Tweet.User")
                name = jsonObject.string("name") ?? ""
                username = try PlatformSDKJSON.requiredString(jsonObject, "username", type: "Tweet.User")
                isVerified = jsonObject.bool("isVerified")
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

        public init(jsonObject: JSONObject) throws {
            id = try PlatformSDKJSON.requiredString(jsonObject, "id", type: "Tweet")
            user = try User(jsonObject: try (jsonObject.dictionary("user")).orThrow(ErrorMessage("Bad Tweet: missing user")))
            text = jsonObject.string("text") ?? ""
            timestamp = PlatformSDKJSON.timestamp(jsonObject["timestamp"])
            url = jsonObject.string("url")
            textAttributes = try jsonObject.dictionary("textAttributes").map(TextAttributes.init(jsonObject:))
            attachments = try jsonObject.hasValue("attachments")
                ? PlatformSDKJSON.objectArray(jsonObject["attachments"]).map(Attachment.init(jsonObject:))
                : nil
            quotedTweet = try jsonObject.dictionary("quotedTweet").map { TweetBox(try Tweet(jsonObject: $0)) }
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

        public init(jsonObject: JSONObject) throws {
            id = try PlatformSDKJSON.requiredString(jsonObject, "id", type: "MessagePreview")
            threadID = jsonObject.string("threadID")
            text = jsonObject.string("text")
            senderID = jsonObject.string("senderID")
            attachments = try jsonObject.hasValue("attachments")
                ? PlatformSDKJSON.objectArray(jsonObject["attachments"]).map(Attachment.init(jsonObject:))
                : nil
        }

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

        public init(jsonObject: JSONObject) throws {
            label = try PlatformSDKJSON.requiredString(jsonObject, "label", type: "MessageButton")
            linkURL = try PlatformSDKJSON.requiredString(jsonObject, "linkURL", type: "MessageButton")
        }

        public var jsonObject: JSONObject {
            [
                "label": label,
                "linkURL": linkURL,
            ]
        }
    }
}
