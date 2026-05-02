import Foundation
import IMessageCore
import PlatformSDK

func appleDateMilliseconds(_ appleDate: Int?) -> Int64? {
    guard let appleDate, appleDate > 0 else {
        return nil
    }
    return (Int64(appleDate) / 1_000_000) + coreFoundationReferenceDateMilliseconds
}

func appleDateIsTruthy(_ appleDate: Int?) -> Bool {
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

func stringFromDataSlice(_ data: Data, start: Int, length: Int) -> String? {
    guard start >= 0, length >= 0, start + length <= data.count else {
        return nil
    }
    return String(data: data[start ..< start + length], encoding: .utf8)
}

func isUUID(_ string: String) -> Bool {
    UUID(uuidString: string) != nil
}

func parseSize(_ size: String?) -> PlatformSDK.Size? {
    guard let size else {
        return nil
    }
    let trimmed = size.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "{", trimmed.last == "}" else {
        return nil
    }
    let numbers = trimmed.dropFirst().dropLast().split(separator: ",", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    guard let widthString = numbers[safe: 0],
          let heightString = numbers[safe: 1],
          let width = Int(widthString),
          let height = Int(heightString),
          width > 0,
          height > 0 else {
        return nil
    }
    return PlatformSDK.Size(width: Double(width), height: Double(height))
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
    legacyAssetURL(path: Array(filePath.utf8).hexString())
}

func digitalTouchAssetURL(uuid: String) -> String {
    legacyAssetURL(path: "dt/\(uuid).mov")
}

func handwritingAssetURL(uuid: String) -> String {
    legacyAssetURL(path: "hw/\(uuid).png")
}

extension String {
    func matches(against regex: NSRegularExpression) -> Bool {
        let range = NSRange(startIndex ..< endIndex, in: self)
        return regex.firstMatch(in: self, range: range) != nil
    }

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

extension PlatformSDK.TextEntity {
    func offsetting(by offset: Int) -> PlatformSDK.TextEntity {
        PlatformSDK.TextEntity(
            from: from + offset,
            to: to + offset,
            bold: bold,
            italic: italic,
            underline: underline,
            strikethrough: strikethrough,
            quote: quote,
            spoiler: spoiler,
            code: code,
            pre: pre,
            codeLanguage: codeLanguage,
            markdown: markdown,
            replaceWith: replaceWith,
            replaceWithMedia: replaceWithMedia,
            link: link,
            mentionedUser: mentionedUser
        )
    }
}
