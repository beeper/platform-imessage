import AppKit
import ApplicationServices
import IMessagePrivateSPI
import Testing
import WindowControl
@testable import IMessage

@MainActor
private func waitForRecoverySmoke(_ condition: () throws -> Bool) throws {
    let timeout: TimeInterval = 3
    let pollInterval: TimeInterval = 0.02
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        pumpSmokeRunLoop(for: pollInterval)
    }
    try #require(try condition(), "Timed out waiting for secondary Space recovery")
}

// Deletes only a sacrificial Space created by this test, never a user's desktop.
// No activation, Space switching, message sends, or conversation deletion.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_SECONDARY_BRIDGED_RECOVERY_SMOKE"] == "1"))
@MainActor
func secondaryMessagesLostOriginalSpaceSmoke() throws {
    try #require(AXIsProcessTrusted())
    Defaults.registerDefaults()
    let originalSecondary = Preferences.useSecondaryMessagesInstance
    Preferences.useSecondaryMessagesInstance = true
    defer { Preferences.useSecondaryMessagesInstance = originalSecondary }
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
    let baseline = try Space.list(.allOSSpaces).map { UInt64($0.raw) }
    let desktop = IMPrivateSPIActiveSpace()
    let coordinator = try BridgedSpacesWindowCoordinator()
    let bridge = try #require(IMPrivateSPISpaceBridgeCreate())
    let app = try runSmokeWorker {
        try MessagesInstanceTarget.launchSecondaryInstance(initialDeepLink: MessagesDeepLink.compose.url())
    }
    try #require(!existing.contains { $0.processIdentifier == app.processIdentifier })
    var source: UInt64 = 0
    defer {
        try? coordinator.dispose()
        if source != 0 { _ = IMPrivateSPISpaceBridgeDestroySpace(bridge, source) }
        app.terminate()
    }
    coordinator.app = app
    let elements = MessagesAppElements(runningApp: app)
    let window = try elements.mainWindow
    let windowID = try window.window().raw
    let created = IMPrivateSPISpaceBridgeCreateSpace(bridge, ["type": 0, "uuid": "Beeper-Recovery-Smoke-\(UUID().uuidString)"])
    try #require(created != 0 && !baseline.contains(created))
    source = created
    try #require(IMPrivateSPISpaceBridgeMoveWindow(bridge, windowID, source))
    try waitForRecoverySmoke { IMPrivateSPISpacesForWindow(windowID)?.map(\.uint64Value) == [source] }
    try runSmokeWorker { try coordinator.makeAutomatable(window) }
    let hidden = try #require(IMPrivateSPISpacesForWindow(windowID)?.first?.uint64Value)
    try #require(hidden != source && hidden != desktop)
    try #require(IMPrivateSPIActiveSpace() == desktop)
    try #require(IMPrivateSPISpaceBridgeDestroySpace(bridge, source))
    try waitForRecoverySmoke { try !Space.list(.allOSSpaces).contains { UInt64($0.raw) == source } }
    source = 0
    // Restoration must not flash the secondary window on the visible desktop.
    app.hide()
    try waitForRecoverySmoke { try elements.app.isHidden() }
    try runSmokeWorker { try coordinator.dispose() }
    let restored = try #require(IMPrivateSPISpacesForWindow(windowID)?.first?.uint64Value)
    let visible = try #require(IMPrivateSPICopyManagedDisplaySpaces()).compactMap { record -> UInt64? in
        guard let current = record["Current Space"] as? [String: Any] else { return nil }
        return (current["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (current["id64"] as? NSNumber)?.uint64Value
    }
    #expect(visible.contains(restored))
    #expect(IMPrivateSPIActiveSpace() == desktop)
    // Individual hosts restore their windows but retain the shared parking
    // pool. It may have existed at baseline or have been created by this test.
    #expect(try PersistentUnknownSpace.isReusable(hidden))
    #expect(try Set(Space.list(.allOSSpaces).map { UInt64($0.raw) }) == Set(baseline).union([hidden]))
    #expect(existing.allSatisfy { !$0.isTerminated })
}
