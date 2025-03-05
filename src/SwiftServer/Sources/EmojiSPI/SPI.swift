import Darwin
import Foundation

// using dlopen to avoid linking directly to private frameworks, which would cause us to immediately crash on launch if the symbols changed

public final class CPKDefaultDataSource {
    public static func localizedName(for character: String) -> String? {
        Bundle(path: "/System/Library/PrivateFrameworks/CharacterPicker.framework")?.load()
        guard let clazz = NSClassFromString("CPKDefaultDataSource") as? NSObject.Type,
              let unmanagedString = clazz.perform(Selector(("localizedCharacterName:")), with: character as NSString),
              let name = unmanagedString.takeUnretainedValue() as? String
        else { return nil }
        return name
    }
}

public final class EMFEmojiToken {
    private let underlying: NSObject

    public init?(character: Character, locale: Locale = .current) {
        Bundle(path: "/System/Library/PrivateFrameworks/EmojiFoundation.framework")?.load()
        guard let clazz = NSClassFromString("EMFEmojiToken"),
              case let uninitialized = clazz.alloc(),
              let unmanaged = uninitialized.perform(Selector(("initWithString:localeIdentifier:")), with: String(character) as NSString, with: locale),
              let token = unmanaged.takeUnretainedValue() as? NSObject
        else { return nil }
        underlying = token
    }

    public var supportsSkinToneVariants: Bool? {
        typealias Getter = @convention(c) (NSObject) -> Bool
        // can't use perform because it doesn't return an object
        guard let method = class_getInstanceMethod(type(of: underlying), Selector(("supportsSkinToneVariants"))) else { return nil }
        let imp = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return imp(underlying)
    }
}

@available(macOS 11, *)
public final class EMFEmojiSearchEngine {
    private let underlying: NSObject

    public init?(locale: Locale) {
        Bundle(path: "/System/Library/PrivateFrameworks/EmojiFoundation.framework")?.load()
        guard let clazz = NSClassFromString("EMFEmojiSearchEngine"),
              case let uninitialized = clazz.alloc(),
              let unmanaged = uninitialized.perform(Selector(("initWithLocale:")), with: locale),
              let engine = unmanaged.takeUnretainedValue() as? NSObject
        else { return nil }
        underlying = engine
    }

    public func query(_ query: String) -> [String] {
        guard let results = underlying.perform(Selector(("performStringQuery:")), with: query) else { return [] }
        return results.takeUnretainedValue() as? [String] ?? []
    }
}
