import Foundation
import Testing
import EmojiSPI

// these tests are very brittle:
// - need to run under en-US locale
// - tied to CharacterPicker.framework data shipping in OS
// - may need multiple runs for classes to properly load?

let locale = Locale(identifier: "en-US")

@Test func localizedDescription() throws {
    let disguised = try CPKDefaultDataSource.localizedName(for: "🥸")
    #expect(disguised == "disguised face")
}


@Test func searchEngine() throws {
    let engine = try EMFEmojiSearchEngine(locale: locale)
    let results = try engine.query("smile")
    #expect(results.first! == "🤣")
}

@Test func supportsSkinToneVariants() throws {
    let pinched = try EMFEmojiToken(character: "🤌", locale: locale)
    #expect(try pinched.supportsSkinToneVariants)

    let tools = try EMFEmojiToken(character: "🛠️", locale: locale)
    #expect(!(try tools.supportsSkinToneVariants))
}

@Test func characterPickerSearch() throws {
    let bear = try CharacterPickerSearch(finding: "🐻")
    #expect(bear.query == "bear face")
    #expect(bear.position == 0)

    let man = try CharacterPickerSearch(finding: "👨")
    #expect(man.query == "man")
    #expect(man.position == 31)
}
