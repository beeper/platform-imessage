import Foundation

// NOTE: globals in Swift are lazy
private let emojiAppleNamesURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources/en.lproj/AppleName.strings")
// keeping as a NSDictionary to avoid bridging costs
private let mapping: NSDictionary? = {
    guard let bplist = try? Data(contentsOf: emojiAppleNamesURL) else { return nil }
    return try? PropertyListSerialization.propertyList(from: bplist, format: nil) as? NSDictionary
}()

func appleEmojiName(for emoji: Character) -> String? {
    mapping?.value(forKey: String(emoji)) as? String
}
