import Testing
@testable import IMessage

@Test func withoutSkinTones() {
    let neutralThumbsUp = "👍"
    #expect(neutralThumbsUp.withoutSkinToneModifiers == neutralThumbsUp)
    for modifiedThumbsUp in ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"] {
        #expect(modifiedThumbsUp.withoutSkinToneModifiers == neutralThumbsUp)
    }
}
