import Foundation

public typealias JSONObject = [String: Any]
public typealias JSONArray = [Any]

func compactDictionary(_ pairs: [String: Any?]) -> JSONObject {
    pairs.compactMapValues { value in
        guard let value, !(value is NSNull) else {
            return nil
        }
        return value
    }
}

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

@attached(member, names: named(init), named(jsonObject))
public macro PlatformSDKJSONObject() = #externalMacro(module: "PlatformSDKMacros", type: "PlatformSDKJSONObjectMacro")

@attached(peer)
public macro PlatformSDKJSONKey(_ name: String) = #externalMacro(module: "PlatformSDKMacros", type: "PlatformSDKJSONKeyMacro")

enum PlatformSDKJSONEncoding {
    static func encode(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        return value
    }

    static func encode<Value: PlatformSDK.JSONValueConvertible>(_ value: Value?) -> Any? {
        value?.jsonValue
    }

    static func encode<Value: PlatformSDK.JSONValueConvertible>(_ value: [Value]?) -> Any? {
        value?.map(\.jsonValue)
    }

    static func encode<Value: PlatformSDK.JSONValueConvertible>(_ value: [String: Value]?) -> Any? {
        value?.mapValues(\.jsonValue)
    }

    static func encode<Value: RawRepresentable>(_ value: Value?) -> Any? where Value.RawValue == String {
        value?.rawValue
    }
}

extension PlatformSDK {
    @PlatformSDKJSONObject
    public struct Paginated<Item: JSONObjectConvertible>: JSONObjectConvertible {
        public let items: [Item]
        public let hasMore: Bool

    }

    @PlatformSDKJSONObject
    public struct PaginatedWithCursors<Item: JSONObjectConvertible>: JSONObjectConvertible {
        public let items: [Item]
        public let hasMore: Bool
        public let oldestCursor: String?
        public let newestCursor: String?

    }
}
