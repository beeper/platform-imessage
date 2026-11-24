import Testing
@testable import IMessage

@Test func loctableStringReadsPlainAndDeviceSpecificEntries() {
    let translations: [String: Any] = [
        "PLAIN": "Șterge",
        "MAC": ["NSStringDeviceSpecificRuleType": ["mac": "Mac", "other": "Other"]],
        "OTHER": ["NSStringDeviceSpecificRuleType": ["other": "Other"]],
        "UNKNOWN_SHAPE": ["NSStringPluralRuleType": ["one": "One"]],
    ]

    #expect(LocalizedStrings.loctableString(in: translations, key: "PLAIN") == "Șterge")
    #expect(LocalizedStrings.loctableString(in: translations, key: "MAC") == "Mac")
    #expect(LocalizedStrings.loctableString(in: translations, key: "OTHER") == "Other")
    #expect(LocalizedStrings.loctableString(in: translations, key: "UNKNOWN_SHAPE") == nil)
    #expect(LocalizedStrings.loctableString(in: translations, key: "MISSING") == nil)
    #expect(LocalizedStrings.loctableString(in: nil, key: "PLAIN") == nil)
}
