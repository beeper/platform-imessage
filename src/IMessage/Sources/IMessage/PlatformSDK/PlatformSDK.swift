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

        public init(jsonObject: JSONObject, item: (JSONObject) throws -> Item) throws {
            items = try PlatformSDKJSON.objectArray(jsonObject["items"]).map(item)
            hasMore = jsonObject.bool("hasMore") ?? false
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

        public init(jsonObject: JSONObject, item: (JSONObject) throws -> Item) throws {
            items = try PlatformSDKJSON.objectArray(jsonObject["items"]).map(item)
            hasMore = jsonObject.bool("hasMore") ?? false
            oldestCursor = jsonObject.string("oldestCursor")
            newestCursor = jsonObject.string("newestCursor")
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

enum PlatformSDKJSON {
    static func requiredString(_ object: JSONObject, _ key: String, type: String) throws -> String {
        try object.string(key).orThrow(ErrorMessage("Bad \(type): missing string \(key)"))
    }

    static func requiredTimestamp(_ object: JSONObject, _ key: String, type: String) throws -> PlatformSDK.Timestamp {
        try timestamp(object[key]).orThrow(ErrorMessage("Bad \(type): missing timestamp \(key)"))
    }

    static func requiredBool(_ object: JSONObject, _ key: String, type: String) throws -> Bool {
        try object.bool(key).orThrow(ErrorMessage("Bad \(type): missing bool \(key)"))
    }

    static func timestamp(_ value: Any?) -> PlatformSDK.Timestamp? {
        switch value {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Double:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value)
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    static func int64(_ value: Any?) -> Int64? {
        timestamp(value)
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    static func objectArray(_ value: Any?) -> [JSONObject] {
        (value as? [JSONObject]) ?? (value as? [Any])?.compactMap { $0 as? JSONObject } ?? []
    }
}
