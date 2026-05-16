import Foundation
import Testing

@Test
private func jsonFixturesDoNotContainPrivateIdentifiers() throws {
    let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    let fixtureURLs = try FileManager.default
        .contentsOfDirectory(at: fixtureDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }

    for url in fixtureURLs {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        try inspectFixtureValue(object, path: url.lastPathComponent)
    }
}

private func inspectFixtureValue(_ value: Any, path: String) throws {
    if let dictionary = value as? [String: Any] {
        for (key, child) in dictionary {
            try inspectFixtureValue(child, path: "\(path).\(key)")
        }
        return
    }

    if let array = value as? [Any] {
        for (index, child) in array.enumerated() {
            try inspectFixtureValue(child, path: "\(path)[\(index)]")
        }
        return
    }

    guard let string = value as? String else {
        return
    }

    try inspectFixtureString(string, path: path)
    if let decoded = decodedDataURLString(string) {
        try inspectFixtureString(decoded, path: "\(path) decoded data")
    }
}

private func inspectFixtureString(_ string: String, path: String) throws {
    #expect(!containsMatch(phoneNumberRegex, in: string), "\(path) contains a phone-number-shaped value")
    #expect(!containsDisallowedEmail(in: string), "\(path) contains a non-fixture email address")
    #expect(!containsDisallowedURL(in: string), "\(path) contains a non-fixture URL")
    #expect(!string.contains("FIXTURE-"), "\(path) contains an old fixture-id marker")
    #expect(!string.contains("-TARGET"), "\(path) contains a suffix-style target GUID")
    #expect(!string.contains("-ATTACHMENT-"), "\(path) contains a suffix-style attachment GUID")
    #expect(!string.contains("/Users/"), "\(path) contains a home-directory path")
    #expect(!string.contains("Library/Messages"), "\(path) contains a Messages data path")
    #expect(!string.contains(legacySampleAccount), "\(path) contains legacy sample account data")
}

private func decodedDataURLString(_ string: String) -> String? {
    let prefix = "data:;base64,"
    guard string.hasPrefix(prefix),
          let data = Data(base64Encoded: String(string.dropFirst(prefix.count))) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

private func containsDisallowedEmail(in string: String) -> Bool {
    matches(emailRegex, in: string).contains { !$0.hasSuffix("@example.invalid") }
}

private func containsDisallowedURL(in string: String) -> Bool {
    matches(urlRegex, in: string).contains { url in
        guard let host = URL(string: url)?.host else {
            return true
        }
        return !host.hasSuffix(".invalid")
    }
}

private func containsMatch(_ regex: NSRegularExpression, in string: String) -> Bool {
    !matches(regex, in: string).isEmpty
}

private func matches(_ regex: NSRegularExpression, in string: String) -> [String] {
    let range = NSRange(string.startIndex ..< string.endIndex, in: string)
    return regex.matches(in: string, range: range).compactMap { match in
        Range(match.range, in: string).map { String(string[$0]) }
    }
}

private let phoneNumberRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])\+[0-9][0-9 .()\-]{6,}[0-9]"#)
private let emailRegex = try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
private let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s"<>\\]+"#, options: [.caseInsensitive])
private let legacySampleAccount = "sjobs" + "@apple.com"
