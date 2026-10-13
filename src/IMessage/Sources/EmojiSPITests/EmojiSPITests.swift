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

private let initializerLocale = Locale(identifier: "pt_PT")
@Test(.serialized, arguments: [false, true])
private func initializerOwnership(fails: Bool) throws {
    InitializerFixture.fails = fails
    InitializerFixture.deinitCount = 0

    var value: AnyObject?
    try autoreleasepool {
        if fails {
            #expect(throws: SPIError.nilResponse(method: "initWithString:localeIdentifier:")) {
                try EMFEmojiToken(character: "🤌", locale: initializerLocale, objectClass: InitializerFixture.self)
            }
        } else {
            value = try EMFEmojiToken(character: "🤌", locale: initializerLocale, objectClass: InitializerFixture.self)
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

    @objc(initWithString:localeIdentifier:)
    init?(string: NSString, localeIdentifier: AnyObject) {
        super.init()
        Self.instance = self
        #expect((localeIdentifier as? String) == initializerLocale.identifier)
        if Self.fails { return nil }
    }

    deinit { Self.deinitCount += 1 }
}

@Test private func pickerSearchUsesPickerLanguages() async throws {
    let results = try await Task.detached {
        try CPKDefaultDataSource.query("celebration", objectClass: PickerSearchFixture.self)
    }.value
    #expect(results == ["🎉", "🥳"])
}

@Test private func pickerSearchRejectsMissingMethods() async {
    await Task.detached {
        #expect(throws: SPIError.nilResponse(method: "emojiTokensForSearchString:inLanguages:maxResults:usingBlock:")) {
            try CPKDefaultDataSource.query("celebration", objectClass: NSObject.self)
        }
    }.value
}

private final class PickerSearchFixture: NSObject {
    @objc static func preferredLanguagesForSearch() -> [String] { ["pt-PT", "en-US"] }

    @objc(emojiTokensForSearchString:inLanguages:maxResults:usingBlock:)
    static func search(_ query: String, languages: [String], maximum: UInt,
                       completion: @escaping @convention(block) (NSArray, Bool) -> Void) {
        #expect(languages == ["pt-PT", "en-US"])
        #expect(maximum == 500)
        let results: [NSObject]
        switch query {
        case "celebration": results = [PickerTokenFixture("🎉"), PickerTokenFixture("🥳")]
        case "missing-string": results = [NSObject(), PickerTokenFixture("🎉")]
        case "non-string": results = [MalformedPickerTokenFixture(NSNumber(value: 1)), PickerTokenFixture("🎉")]
        case "nil-string": results = [MalformedPickerTokenFixture(nil), PickerTokenFixture("🎉")]
        case "empty-string": results = [MalformedPickerTokenFixture("" as NSString), PickerTokenFixture("🎉")]
        default:
            Issue.record("Unexpected fixture query: \(query)")
            results = []
        }
        DispatchQueue.global().async {
            completion(results as NSArray, false)
        }
    }
}

private final class PickerTokenFixture: NSObject {
    @objc let string: String
    init(_ string: String) { self.string = string }
}

private final class MalformedPickerTokenFixture: NSObject {
    @objc let string: AnyObject?
    init(_ string: AnyObject?) { self.string = string }
}

@Test(arguments: ["missing-string", "non-string", "nil-string", "empty-string"])
private func pickerSearchRejectsMalformedTokens(query: String) async {
    await Task.detached {
        #expect(throws: SPIError.nilResponse(method: "emojiTokensForSearchString:inLanguages:maxResults:usingBlock:")) {
            try CPKDefaultDataSource.query(query, objectClass: PickerSearchFixture.self)
        }
    }.value
}
