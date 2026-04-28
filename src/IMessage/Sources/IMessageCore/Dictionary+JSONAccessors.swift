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

    mutating func mutateDictionary(_ key: String, _ body: (inout [String: Any]) -> Void) {
        var value = dictionary(key) ?? [:]
        body(&value)
        self[key] = value
    }

    func stringifying(_ key: String) -> String? {
        guard let value = self[key], !(value is NSNull) else {
            return nil
        }
        return "\(value)"
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    func data(_ key: String) -> Data? {
        guard let value = self[key], !(value is NSNull) else {
            return nil
        }
        switch value {
        case let data as Data:
            return data
        case let data as NSData:
            return data as Data
        default:
            return nil
        }
    }

    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func array(_ key: String) -> [Any] {
        (self[key] as? [Any]) ?? []
    }

    func hasValue(_ key: String) -> Bool {
        guard let value = self[key] else {
            return false
        }
        return !(value is NSNull)
    }
}
