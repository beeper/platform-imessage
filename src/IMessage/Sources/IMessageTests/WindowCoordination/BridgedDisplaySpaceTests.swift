import CoreGraphics
import Testing
@testable import IMessage

private let displaySize: CGFloat = 100
private let leftDisplay = BridgedDisplaySpace(identifier: "left", space: 1, bounds: CGRect(x: 0, y: 0, width: displaySize, height: displaySize))
private let rightDesktop: UInt64 = 2
private let rightDisplay = BridgedDisplaySpace(identifier: "right", space: rightDesktop, bounds: CGRect(x: displaySize, y: 0, width: displaySize, height: displaySize))

@Test
func bridgedRestorationUsesRememberedDisplayEvenWhenParkedElsewhere() {
    let destination = BridgedDisplaySpace.destination(
        preferredDisplay: "right",
        windowFrame: leftDisplay.bounds,
        displays: [leftDisplay, rightDisplay]
    )
    #expect(destination?.space == 2)
}

@Test
func bridgedRestorationUsesRelocatedWindowWhenDisplayDisconnects() {
    let destination = BridgedDisplaySpace.destination(
        preferredDisplay: "disconnected",
        windowFrame: rightDisplay.bounds,
        displays: [leftDisplay, rightDisplay]
    )
    #expect(destination?.space == 2)
}

@Test
func bridgedRestorationUsesCurrentDesktopOnAssociatedDisplay() {
    let updated = BridgedDisplaySpace(identifier: "right", space: 3, bounds: rightDisplay.bounds)
    let destination = BridgedDisplaySpace.destination(
        preferredDisplay: "right",
        windowFrame: leftDisplay.bounds,
        displays: [leftDisplay, updated]
    )
    #expect(destination?.space == 3)
    #expect(BridgedDisplaySpace.destination(preferredDisplay: "right", windowFrame: .zero, displays: []) == nil)
}
