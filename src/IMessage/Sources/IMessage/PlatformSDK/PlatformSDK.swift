import Foundation
import IMessageCore

/// Swift models for the public shapes defined by `@textshq/platform-sdk`
/// https://github.com/TextsHQ/platform-sdk
public enum PlatformSDK {
    public typealias ID = String
    public typealias UserID = ID
    public typealias ThreadID = ID
    public typealias MessageID = ID
    public typealias AttachmentID = ID
    /// `platform-sdk` exposes these as `Date`; across the JSON bridge we emit epoch milliseconds.
    public typealias Timestamp = Int64
}

public extension PlatformSDK {
    protocol JSONValueConvertible {
        var jsonValue: Any { get }
    }

    protocol JSONObjectConvertible: JSONValueConvertible {
        var jsonObject: JSONObject { get }
    }
}

public extension PlatformSDK.JSONObjectConvertible {
    var jsonValue: Any { jsonObject }
}

extension PlatformSDK {
    public struct Paginated<Item: JSONObjectConvertible>: JSONObjectConvertible {
        public let items: [Item]
        public let hasMore: Bool

        public init(items: [Item], hasMore: Bool) {
            self.items = items
            self.hasMore = hasMore
        }

        public var jsonObject: JSONObject {
            [
                "items": items.map(\.jsonObject),
                "hasMore": hasMore,
            ]
        }
    }

    public struct PaginatedWithCursors<Item: JSONObjectConvertible>: JSONObjectConvertible {
        public let items: [Item]
        public let hasMore: Bool
        public let oldestCursor: String?
        public let newestCursor: String?

        public init(items: [Item], hasMore: Bool, oldestCursor: String? = nil, newestCursor: String? = nil) {
            self.items = items
            self.hasMore = hasMore
            self.oldestCursor = oldestCursor
            self.newestCursor = newestCursor
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "items": items.map(\.jsonObject),
                "hasMore": hasMore,
                "oldestCursor": oldestCursor,
                "newestCursor": newestCursor,
            ])
        }
    }
}
