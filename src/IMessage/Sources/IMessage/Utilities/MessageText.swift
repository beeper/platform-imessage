import Foundation

func containsLink(_ text: String) -> Bool {
    linkCount(in: text) > 0
}

func linkCount(in text: String) -> Int {
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
    return matches?.count ?? 0
}
