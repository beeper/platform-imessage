import Foundation
import IMessageCore
import PlatformSDK

func jsonStringify<T: Encodable>(_ input: T) throws -> String {
    let data = try encoder.encode(input)
    return String(decoding: data, as: UTF8.self)
}

public func encodeJSON(_ value: Any?) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: jsonSerializable(value), options: [.fragmentsAllowed])
    return try String(data: data, encoding: .utf8).orThrow(ErrorMessage("Swift message API output wasn't utf8"))
}

private func jsonSerializable(_ value: Any?) -> Any {
    guard let value else {
        return NSNull()
    }

    if let optional = value as? OptionalProtocol {
        return jsonSerializable(optional.anyValue)
    }

    switch value {
    case let string as String:
        return jsonSafeString(string)
    case let data as Data:
        return data.dataURL
    case let data as NSData:
        return data.dataURL
    case let dictionary as [String: Any]:
        return dictionary.reduce(into: JSONObject()) { result, element in
            result[jsonSafeString(element.key)] = jsonSerializable(element.value)
        }
    case let dictionary as NSDictionary:
        var result = JSONObject()
        for (key, child) in dictionary {
            guard let key = key as? String else {
                continue
            }
            result[jsonSafeString(key)] = jsonSerializable(child)
        }
        return result
    case let array as [Any]:
        return array.map(jsonSerializable)
    case let array as NSArray:
        return array.map(jsonSerializable)
    case let url as URL:
        return url.absoluteString
    case let url as NSURL:
        return url.absoluteString ?? ""
    default:
        return value
    }
}

private func jsonSafeString(_ string: String) -> String {
    String(decoding: string.utf8, as: UTF8.self)
}

private let encoder = JSONEncoder()
