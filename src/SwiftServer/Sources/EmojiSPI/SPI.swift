import Darwin
import Foundation

// using dlopen to avoid linking directly to private frameworks, which would cause us to immediately crash on launch if the symbols changed

public final class CPKDefaultDataSource {
    public static func localizedName(for character: String) -> String? {
        Bundle(path: "/System/Library/PrivateFrameworks/CharacterPicker.framework")?.load()
        guard let clazz = NSClassFromString("CPKDefaultDataSource") as? NSObject? else { return nil }
        guard let string = clazz?.perform(Selector(("localizedCharacterName:")), with: character as NSString) as? Unmanaged<NSString>? else { return nil }
        guard let name = string?.takeUnretainedValue() as? String else { return nil }
        return name
    }
}

@available(macOS 11, *)
public final class EMFEmojiSearchEngine {
    private let underlying: NSObject

    public init?(locale: Locale) {
        Bundle(path: "/System/Library/PrivateFrameworks/EmojiFoundation.framework")?.load()
        guard let clazz = NSClassFromString("EMFEmojiSearchEngine") else { return nil }
        let uninitialized = clazz.alloc()
        guard let instance = uninitialized.perform(Selector(("initWithLocale:")), with: locale) else { return nil }
        underlying = instance.takeUnretainedValue() as! NSObject
    }

    public func query(_ query: String) -> [String] {
        guard let results = underlying.perform(Selector(("performStringQuery:")), with: query) else { return [] }
        return results.takeUnretainedValue() as? [String] ?? []
    }
}
