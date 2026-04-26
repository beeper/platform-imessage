import Foundation

func appleDateMilliseconds(_ appleDate: String?) -> Int64? {
    guard let appleDate, appleDate != "0", let nanos = Int64(appleDate) else {
        return nil
    }
    return (nanos / 1_000_000) + coreFoundationReferenceDateMilliseconds
}

func dateStringIsTruthy(_ appleDate: String?) -> Bool {
    appleDate.flatMap(appleDateMilliseconds) != nil
}

func removeObjectReplacementCharacter(_ text: String) -> String {
    guard text.contains(objectReplacementCharacter) else {
        return text
    }
    return text.replacingOccurrences(of: objectReplacementCharacter, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

// IMDB stores account logins as `E:foo@bar.com` / `P:+15551234`.
func mapAccountLogin(_ accountLogin: String) -> String {
    switch accountLogin {
    case let value where value.hasPrefix("E:") || value.hasPrefix("P:"):
        return String(value.dropFirst(2))
    default:
        return accountLogin
    }
}

func compactDictionary(_ pairs: [String: Any?]) -> JSONObject {
    pairs.compactMapValues { value in
        guard let value, !(value is NSNull) else {
            return nil
        }
        return value
    }
}

func stringFromDataSlice(_ data: Data, start: Int, length: Int) -> String? {
    guard start >= 0, length >= 0, start + length <= data.count else {
        return nil
    }
    return String(data: data[start ..< start + length], encoding: .utf8)
}

func isUUID(_ string: String) -> Bool {
    UUID(uuidString: string) != nil
}

private let sizeRegex = try! NSRegularExpression(pattern: #"\{(\d+), (\d+)\}"#)

func parseSize(_ size: String?) -> [String: Int]? {
    guard let size,
          let match = size.firstMatch(against: sizeRegex),
          let width = Int(match[1]),
          let height = Int(match[2]),
          width > 0,
          height > 0 else {
        return nil
    }
    return ["width": width, "height": height]
}

func relativeURL(_ value: Any?) -> String? {
    switch value {
    case let string as String:
        return string
    case let url as URL:
        return url.absoluteString
    case let url as NSURL:
        return url.absoluteString
    case let object as JSONObject:
        return object.string("NS.relative") ?? object.string("relative") ?? object.string("url")
    default:
        return nil
    }
}

func unquote(_ string: String) -> String {
    if string.first == "“", string.last == "”" {
        return String(string.dropFirst().dropLast())
    }
    return string
}

func isXHost(_ url: String) -> Bool {
    guard let host = URL(string: url)?.host else {
        return false
    }
    return host == "twitter.com" || host == "x.com"
}

private let tweetURLRegex = try! NSRegularExpression(
    pattern: #"https?://(?:[a-z]+\.)?(?:twitter|x)\.com/(.+?)/status/(\d+)"#
)

func parseTweetURL(_ url: String) -> (username: String, tweetID: String)? {
    guard let match = url.firstMatch(against: tweetURLRegex) else {
        return nil
    }
    return (username: match[1], tweetID: match[2])
}

private let legacyAssetAccountPlaceholder = "$accountID"

private func legacyAssetURL(path: String) -> String {
    "asset://\(legacyAssetAccountPlaceholder)/\(path)"
}

func fileAttachmentAssetURL(filePath: String) -> String {
    legacyAssetURL(path: filePath.utf8.map { String(format: "%02x", $0) }.joined())
}

func digitalTouchAssetURL(uuid: String) -> String {
    legacyAssetURL(path: "dt/\(uuid).mov")
}

func handwritingAssetURL(uuid: String) -> String {
    legacyAssetURL(path: "hw/\(uuid).png")
}

extension String {
    func firstMatch(against regex: NSRegularExpression) -> [String]? {
        let range = NSRange(startIndex ..< endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range) else {
            return nil
        }
        return (0 ..< match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: self) else {
                return ""
            }
            return String(self[range])
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Dictionary where Key == String, Value == Any {
    mutating func mutateDictionary(_ key: String, _ body: (inout JSONObject) -> Void) {
        var value = dictionary(key) ?? [:]
        body(&value)
        self[key] = value
    }

    func string(_ key: String) -> String? {
        if let value = self[key] as? String {
            return value
        }
        if let number = self[key] as? NSNumber {
            return "\(number)"
        }
        return nil
    }

    func stringifying(_ key: String) -> String? {
        guard let value = self[key], !(value is NSNull) else {
            return nil
        }
        return "\(value)"
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.intValue
        }
        if let value = self[key] as? String {
            return Int(value)
        }
        return nil
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

    func dictionary(_ key: String) -> JSONObject? {
        self[key] as? JSONObject
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

    func dataURI(_ key: String) -> Data? {
        guard let value = self[key] as? String,
              let comma = value.firstIndex(of: ",") else {
            return nil
        }
        return Data(base64Encoded: String(value[value.index(after: comma)...]))
    }
}
