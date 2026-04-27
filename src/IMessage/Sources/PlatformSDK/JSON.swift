import Foundation

public typealias JSONObject = PlatformSDK.JSONObject
public typealias JSONArray = PlatformSDK.JSONArray

public func compactDictionary(_ pairs: [String: Any?]) -> JSONObject {
    pairs.compactMapValues { value in
        guard let value, !(value is NSNull) else {
            return nil
        }
        return value
    }
}

public extension PlatformSDK {
    typealias JSONObject = [String: Any]
    typealias JSONArray = [Any]

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
