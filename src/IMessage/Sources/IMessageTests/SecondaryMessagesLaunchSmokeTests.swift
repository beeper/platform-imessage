// swiftlint:disable no_magic_numbers
import AppKit
import Darwin
import Testing
@testable import IMessage

// Explicit opt-in: this launches and closes a real secondary Messages process.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_SECONDARY_LAUNCH_SMOKE"] == "1"))
@MainActor
func secondaryMessagesLaunchSmoke() throws {
    Defaults.registerDefaults()
    try #require(Defaults.dockSuppression, "Requires Dock suppression")
    let originalSecondary = Preferences.useSecondaryMessagesInstance
    Preferences.useSecondaryMessagesInstance = true
    defer { Preferences.useSecondaryMessagesInstance = originalSecondary }
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
    let baselineDock = try messagesDockSnapshot()
    let compose = try #require(URL(string: "imessage:open?address=&body"))
    let app = try runSmokeWorker {
        try MessagesInstanceTarget.launchSecondaryInstance(initialDeepLink: compose)
    }
    defer { if !app.isTerminated { app.terminate() } }
    #expect(!existing.contains { $0.processIdentifier == app.processIdentifier })

    for _ in 0..<3 {
        try MessagesInstanceTarget.sendDeepLink(compose, to: app)
        pumpSmokeRunLoop(for: 0.5)
        #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
        #expect(!app.isActive)
        try expectSecondaryDock(phase: "deep-link", baseline: baselineDock, additionalTiles: 0)
        let windows = try #require(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        #expect(!windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier })
    }
    // Exercise the shared coordinator hooks without moving or resizing a window.
    let coordinator = EclipsingWindowCoordinator()
    coordinator.app = app
    try coordinator.restoreDockPresence()
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    try expectSecondaryDock(phase: "restored", baseline: baselineDock, additionalTiles: 1)
    try coordinator.suppressDockPresence()
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
    try expectSecondaryDock(phase: "resuppressed", baseline: baselineDock, additionalTiles: 0)
    try coordinator.restoreDockPresence()
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    try expectSecondaryDock(phase: "restored", baseline: baselineDock, additionalTiles: 1)
    #expect(existing.allSatisfy { !$0.isTerminated })
    #expect(app.terminate())
    let deadline = Date().addingTimeInterval(5)
    while kill(app.processIdentifier, 0) == 0 && Date() < deadline {
        pumpSmokeRunLoop(for: 0.05)
    }
    #expect(kill(app.processIdentifier, 0) == -1 && errno == ESRCH)
}

@MainActor
private func expectSecondaryDock(phase: String, baseline: MessagesDockSnapshot, additionalTiles: Int) throws {
    let snapshot = try messagesDockSnapshot()
    print("SECONDARY_DOCK phase=\(phase) tiles=\(snapshot.tiles) baseline=\(baseline.tiles) running=\(snapshot.running)")
    // Dock can reuse an existing Recent Applications tile when restoring.
    if additionalTiles == 0 {
        #expect(snapshot.tiles == baseline.tiles)
    } else {
        #expect((baseline.tiles...(baseline.tiles + additionalTiles)).contains(snapshot.tiles))
    }
    #expect(snapshot.running == baseline.running + additionalTiles)
}

// swiftlint:enable no_magic_numbers
