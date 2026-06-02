import Foundation
@testable import IMessage
import Testing

// MARK: parts 1+ (explicit part index)

@Test func resolveExplicitPartIndexAddressedDirectly() {
    #expect(resolveMessageCellResolution(partIndex: 2, partCount: 3, targetPartExists: true, overlay: true) == .direct(partIndex: 2))
    #expect(resolveMessageCellResolution(partIndex: 2, partCount: 3, targetPartExists: true, overlay: false) == .direct(partIndex: 2))
}

@Test func resolveExplicitPartIndexMissingThrows() {
    #expect(resolveMessageCellResolution(partIndex: 2, partCount: 2, targetPartExists: false, overlay: true) == .partNotFound)
    #expect(resolveMessageCellResolution(partIndex: 5, partCount: 3, targetPartExists: false, overlay: false) == .partNotFound)
}

// MARK: part 0 / bare GUID (single-part and multi-part treated identically)

@Test func resolveOverlayUsesBareGUID() {
    #expect(resolveMessageCellResolution(partIndex: nil, partCount: 1, targetPartExists: true, overlay: true) == .direct(partIndex: nil))
    #expect(resolveMessageCellResolution(partIndex: nil, partCount: 3, targetPartExists: true, overlay: true) == .direct(partIndex: nil))
}

@Test func resolveNonOverlayPartZeroUsesClosestSelectable() {
    #expect(resolveMessageCellResolution(partIndex: nil, partCount: 1, targetPartExists: true, overlay: false) == .closestSelectable)
    #expect(resolveMessageCellResolution(partIndex: nil, partCount: 3, targetPartExists: true, overlay: false) == .closestSelectable)
}

@Test func resolveMissingPartZeroThrowsOnFallback() {
    #expect(resolveMessageCellResolution(partIndex: nil, partCount: 3, targetPartExists: false, overlay: false) == .partNotFound)
}

// MARK: messages with no parsed parts

@Test func resolveEmptyPartsUsesBareGUID() {
    #expect(resolveMessageCellResolution(partIndex: nil, partCount: 0, targetPartExists: false, overlay: false) == .direct(partIndex: nil))
}
