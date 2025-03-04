// duplicated from SwiftServer
import Foundation

enum AppleEmojiNames {
    private static let stringsURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources/en.lproj/AppleName.strings")

    // keeping as a NSDictionary to avoid bridging costs
    static let mapping: NSDictionary? = {
        guard let bplist = try? Data(contentsOf: stringsURL) else { return nil }
        return try? PropertyListSerialization.propertyList(from: bplist, format: nil) as? NSDictionary
    }()

    static subscript(for emoji: Character) -> String? {
        mapping?.value(forKey: String(emoji)) as? String
    }
}
