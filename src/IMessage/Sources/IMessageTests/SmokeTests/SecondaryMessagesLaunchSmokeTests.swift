// swiftlint:disable no_magic_numbers
import AppKit
import Darwin
import IMessageCore
import Testing
@testable import IMessage

// Explicit opt-in: this launches and closes a real secondary Messages process.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_SECONDARY_LAUNCH_SMOKE"] == "1"))
@MainActor
func secondaryMessagesLaunchSmoke() async throws {
    Defaults.registerDefaults()
    try #require(Defaults.dockSuppression, "Requires Dock suppression")
    let originalSecondary = Preferences.useSecondaryMessagesInstance
    Preferences.useSecondaryMessagesInstance = true
    defer { Preferences.useSecondaryMessagesInstance = originalSecondary }
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
    let baselineDock = try messagesDockSnapshot()
    let compose = try #require(URL(string: "imessage:open?address=&body"))
    let app = try await runSmokeWorker {
        try await MessagesInstanceTarget.launchSecondaryInstance(initialDeepLink: compose)
    }
    defer { if !app.isTerminated { app.terminate() } }
    #expect(!existing.contains { $0.processIdentifier == app.processIdentifier })

    for _ in 0..<3 {
        try MessagesInstanceTarget.sendDeepLink(compose, to: app)
        try await Task.sleep(forTimeInterval: 0.5)
        #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
        #expect(!app.isActive)
        try await expectSecondaryDock(phase: "deep-link", baseline: baselineDock, additionalTiles: 0)
        let windows = try #require(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        #expect(!windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier })
    }
    // Exercise the shared coordinator hooks without moving or resizing a window.
    let coordinator = EclipsingWindowCoordinator()
    coordinator.app = app
    try await coordinator.restoreDockPresence()
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    try await expectSecondaryDock(phase: "restored", baseline: baselineDock, additionalTiles: 1)
    // Suppressing from Foreground waits ~1s between transitions; none of it may block main.
    let stall = try await longestMainActorStall { try await coordinator.suppressDockPresence() }
    print("SECONDARY_DOCK suppress main-actor stall=\(stall)")
    #expect(stall < 0.25, "Dock suppression must not block the main actor")
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
    try await expectSecondaryDock(phase: "resuppressed", baseline: baselineDock, additionalTiles: 0)
    try await coordinator.restoreDockPresence()
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    try await expectSecondaryDock(phase: "restored", baseline: baselineDock, additionalTiles: 1)
    #expect(existing.allSatisfy { !$0.isTerminated })
    #expect(app.terminate())
    let deadline = Date().addingTimeInterval(5)
    while kill(app.processIdentifier, 0) == 0 && Date() < deadline {
        try await Task.sleep(forTimeInterval: 0.05)
    }
    #expect(kill(app.processIdentifier, 0) == -1 && errno == ESRCH)
}

/// Runs `operation` while a main-actor heartbeat records the longest gap between ticks,
/// including the gap up to completion (a fully synchronous block never lets it tick).
@MainActor
private func longestMainActorStall(_ operation: () async throws -> Void) async throws -> TimeInterval {
    let ticks = Protected((last: Date(), longest: TimeInterval(0)))
    let heartbeat = Task { @MainActor in
        while !Task.isCancelled {
            try? await Task.sleep(forTimeInterval: 0.01)
            let now = Date()
            ticks.withLock { $0 = (now, max($0.longest, now.timeIntervalSince($0.last))) }
        }
    }
    defer { heartbeat.cancel() }
    try await operation()
    let final = ticks.read()
    return max(final.longest, Date().timeIntervalSince(final.last))
}

@MainActor
private func expectSecondaryDock(phase: String, baseline: MessagesDockSnapshot, additionalTiles: Int) async throws {
    // Dock adds and removes tiles asynchronously after a presentation change. On timeout,
    // fall through so the expectations below report the actual counts.
    try? await waitForSmoke("Dock \(phase)", timeout: 3) {
        let snapshot = try messagesDockSnapshot()
        return snapshot.running == baseline.running + additionalTiles &&
            (baseline.tiles...(baseline.tiles + additionalTiles)).contains(snapshot.tiles)
    }
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
