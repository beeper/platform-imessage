import Foundation

/// Filters `nil` and `NSNull` values from a stringly-keyed optional dictionary.
public func compactDictionary(_ pairs: [String: Any?]) -> [String: Any] {
    pairs.compactMapValues { value in
        guard let value, !(value is NSNull) else { return nil }
        return value
    }
}

public extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        switch value {
        case let string as String: return string
        case let number as NSNumber: return "\(number)"
        default: return nil
        }
    }

    func int(_ key: String) -> Int? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        switch value {
        case let integer as Int: return integer
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }
}
