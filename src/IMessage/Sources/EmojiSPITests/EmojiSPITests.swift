import Foundation
import Testing
@testable import EmojiSPI

// The framework tests depend on the installed emoji data and an English system language.

let locale = Locale(identifier: "en-US")

@Test func localizedDescription() throws {
    let disguised = try CPKDefaultDataSource.localizedName(for: "🥸")
    #expect(disguised == "disguised face")
}

@Test func supportsSkinToneVariants() throws {
    let pinched = try EMFEmojiToken(character: "🤌", locale: locale)
    #expect(try pinched.supportsSkinToneVariants)

    let tools = try EMFEmojiToken(character: "🛠️", locale: locale)
    #expect(!(try tools.supportsSkinToneVariants))
}

private let emojiInitializers: [(method: String, make: () throws -> AnyObject)] = [
    ("initWithLocale:", {
        try EMFEmojiSearchEngine(locale: locale, objectClass: InitializerFixture.self)
    }),
    ("initWithString:localeIdentifier:", {
        try EMFEmojiToken(character: "🤌", locale: locale, objectClass: InitializerFixture.self)
    }),
]

@Test(.serialized, arguments: emojiInitializers, [false, true])
private func initializerOwnership(initializer: (method: String, make: () throws -> AnyObject), fails: Bool) throws {
    InitializerFixture.fails = fails
    InitializerFixture.deinitCount = 0

    var value: AnyObject?
    try autoreleasepool {
        if fails {
            #expect(throws: SPIError.nilResponse(method: initializer.method)) {
                try initializer.make()
            }
        } else {
            value = try initializer.make()
        }
    }

    withExtendedLifetime(value) {
        #expect((InitializerFixture.instance == nil) == fails)
        #expect(InitializerFixture.deinitCount == (fails ? 1 : 0))
    }

    autoreleasepool { value = nil }
    #expect(InitializerFixture.instance == nil)
    #expect(InitializerFixture.deinitCount == 1)
}

private final class InitializerFixture: NSObject {
    static var fails = false
    static var deinitCount = 0
    static weak var instance: InitializerFixture?

    @objc(initWithLocale:)
    init?(locale: NSLocale) {
        super.init()
        Self.instance = self
        if Self.fails { return nil }
    }

    @objc(initWithString:localeIdentifier:)
    init?(string: NSString, localeIdentifier: AnyObject) {
        super.init()
        Self.instance = self
        if Self.fails { return nil }
    }

    deinit { Self.deinitCount += 1 }
}
