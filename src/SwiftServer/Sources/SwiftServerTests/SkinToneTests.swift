import Testing
@testable import SwiftServer

@Test func withoutSkinTones() {
    let neutralThumbsUp = "👍"
    #expect(neutralThumbsUp.withoutSkinToneModifiers == neutralThumbsUp)
    for modifiedThumbsUp in ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"] {
        #expect(modifiedThumbsUp.withoutSkinToneModifiers == neutralThumbsUp)
    }
}
