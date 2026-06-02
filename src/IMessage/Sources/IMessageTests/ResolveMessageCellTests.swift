import Foundation
@testable import IMessage
import Testing

// MARK: parts 1+ (explicit part index)

@Test func resolveExplicitPartIndexAddressedDirectly() {
    #expect(
        resolveMessageCellResolution(partIndex: 2, partCount: 3, targetPartExists: true, isMontereyOrUp: true, overlay: true)
            == .direct(partIndex: 2)
    )
    #expect(
        resolveMessageCellResolution(partIndex: 2, partCount: 3, targetPartExists: true, isMontereyOrUp: true, overlay: false)
            == .direct(partIndex: 2)
    )
}

@Test func resolveExplicitPartIndexMissingThrows() {
    #expect(
        resolveMessageCellResolution(partIndex: 2, partCount: 2, targetPartExists: false, isMontereyOrUp: true, overlay: true)
            == .partNotFound
    )
    #expect(
        resolveMessageCellResolution(partIndex: 5, partCount: 3, targetPartExists: false, isMontereyOrUp: false, overlay: false)
            == .partNotFound
    )
}

// MARK: multi-part part 0 (the new unify branch)

@Test func resolveMultipartPartZeroUnifiedToDirectOnMonterey() {
    #expect(
        resolveMessageCellResolution(partIndex: nil, partCount: 3, targetPartExists: true, isMontereyOrUp: true, overlay: false)
            == .direct(partIndex: 0)
    )
    #expect(
        resolveMessageCellResolution(partIndex: nil, partCount: 3, targetPartExists: true, isMontereyOrUp: true, overlay: true)
            == .direct(partIndex: 0)
    )
}

@Test func resolveMultipartPartZeroFallsBackPreMonterey() {
    #expect(
        resolveMessageCellResolution(partIndex: nil, partCount: 3, targetPartExists: true, isMontereyOrUp: false, overlay: false)
            == .closestSelectable
    )
}

@Test func resolveMultipartMissingPartZeroThrowsOnFallback() {
    #expect(
        resolveMessageCellResolution(partIndex: nil, partCount: 3, targetPartExists: false, isMontereyOrUp: false, overlay: false)
            == .partNotFound
    )
    #expect(
        resolveMessageCellResolution(partIndex: nil, partCount: 3, targetPartExists: false, isMontereyOrUp: true, overlay: false)
            == .partNotFound
    )
}

// MARK: single-part messages (stay on the bare-GUID path, not p:0)

@Test func resolveSinglePartOverlayUsesBareGUID() {
    #expect(
        resolveMessageCellResolution(partIndex: nil, partCount: 1, targetPartExists: true, isMontereyOrUp: true, overlay: true)
            == .direct(partIndex: nil)
    )
}

@Test func resolveSinglePartNonOverlayUsesClosestSelectable() {
    #expect(
        resolveMessageCellResolution(partIndex: nil, partCount: 1, targetPartExists: true, isMontereyOrUp: true, overlay: false)
            == .closestSelectable
    )
}

// MARK: messages with no parsed parts

@Test func resolveEmptyPartsUsesBareGUID() {
    #expect(
        resolveMessageCellResolution(partIndex: nil, partCount: 0, targetPartExists: false, isMontereyOrUp: true, overlay: false)
            == .direct(partIndex: nil)
    )
    #expect(
        resolveMessageCellResolution(partIndex: nil, partCount: 0, targetPartExists: false, isMontereyOrUp: false, overlay: false)
            == .direct(partIndex: nil)
    )
}
