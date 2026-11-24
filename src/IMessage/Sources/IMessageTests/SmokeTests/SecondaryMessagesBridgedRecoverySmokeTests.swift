import AppKit
import ApplicationServices
import Testing
import WindowControl
@testable import IMessage

// Deletes only a sacrificial Space created by this test, never a user's desktop.
// No activation, Space switching, message sends, or conversation deletion.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_SECONDARY_BRIDGED_RECOVERY_SMOKE"] == "1"))
@MainActor
func secondaryMessagesLostOriginalSpaceSmoke() async throws {
    try #require(AXIsProcessTrusted())
    Defaults.registerDefaults()
    let originalSecondary = Preferences.useSecondaryMessagesInstance
    Preferences.useSecondaryMessagesInstance = true
    defer { Preferences.useSecondaryMessagesInstance = originalSecondary }
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
    let baseline = try Space.list(.allOSSpaces).map(\.raw)
    let desktop = smokeActiveSpaceID()
    let coordinator = try BridgedSpacesWindowCoordinator()
    let bridge = try #require(SpaceBridge())
    let app = try await runSmokeWorker {
        try await MessagesInstanceTarget.launchSecondaryInstance(initialDeepLink: MessagesDeepLink.compose.url())
    }
    try #require(!existing.contains { $0.processIdentifier == app.processIdentifier })
    var source: Space?
    defer {
        try? coordinator.dispose()
        if let source { try? bridge.destroy(source) }
        app.terminate()
    }
    coordinator.app = app
    let elements = smokeElements(runningApp: app)
    let window = try await runSmokeWorker { try await elements.mainWindow }
    let windowID = try window.window().raw
    let created = try bridge.createSpace(values: ["type": 0, "uuid": "Beeper-Recovery-Smoke-\(UUID().uuidString)"])
    try #require(!baseline.contains(created.raw))
    source = created
    try bridge.move(Window(raw: windowID), toManagedSpace: created)
    try await waitForSmoke("secondary Space recovery", timeout: 3) { smokeSpaceIDs(forWindow: windowID) == [created.raw] }
    try runSmokeWorker { try coordinator.makeAutomatable(window) }
    let hidden = try #require(smokeSpaceIDs(forWindow: windowID)?.first)
    try #require(hidden != created.raw && hidden != desktop)
    try #require(smokeActiveSpaceID() == desktop)
    try bridge.destroy(created)
    try await waitForSmoke("secondary Space recovery", timeout: 3) { try !Space.exists(created.raw) }
    source = nil
    // Restoration must not flash the secondary window on the visible desktop.
    app.hide()
    try await waitForSmoke("secondary Space recovery", timeout: 3) { try elements.app.isHidden() }
    try runSmokeWorker { try coordinator.dispose() }
    let restored = try #require(smokeSpaceIDs(forWindow: windowID)?.first)
    let visible = try Display.managedSpaces().compactMap(\.currentSpace)
    #expect(visible.contains(restored))
    #expect(smokeActiveSpaceID() == desktop)
    // Individual hosts restore their windows but retain the shared parking
    // pool. It may have existed at baseline or have been created by this test.
    #expect(try PersistentUnknownSpace.isReusable(hidden))
    #expect(try Set(Space.list(.allOSSpaces).map(\.raw)) == Set(baseline).union([hidden]))
    #expect(existing.allSatisfy { !$0.isTerminated })
}
