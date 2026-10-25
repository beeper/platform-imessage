// swiftlint:disable no_magic_numbers
import AppKit
import ApplicationServices
import Testing
@testable import IMessage

// Opt-in only: drives activation and automation of a real secondary Messages.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_SECONDARY_ACTIVATION_SMOKE"] == "1"))
@MainActor
func secondaryMessagesActivationDockSmoke() throws {
    try #require(AXIsProcessTrusted(), "Secondary activation smoke requires Accessibility permission")
    Defaults.registerDefaults()
    try #require(Defaults.dockSuppression && Defaults.shouldCoordinateWindow, "Requires Dock suppression and window coordination")
    let originalSecondary = Preferences.useSecondaryMessagesInstance
    Preferences.useSecondaryMessagesInstance = true
    defer { Preferences.useSecondaryMessagesInstance = originalSecondary }
    let previousFrontmost = NSWorkspace.shared.frontmostApplication
    defer { previousFrontmost?.activate(options: []) }
    let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).map(\.processIdentifier))
    let baseline = try messagesDockSnapshot()
    let controller = try runSmokeWorker {
        try MessagesController(reportErrorMessage: { Issue.record(Comment(rawValue: $0)) })
    }
    defer { controller.dispose() }
    let app = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).first {
        !existingPIDs.contains($0.processIdentifier)
    })
    // Prove activation restores a suppressed instance through the lifecycle observer.
    try #require(!app.isActive)
    try #require(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
    // Let lifecycle observation finish starting before testing user activation.
    pumpSmokeRunLoop(for: 1)
    try #require(app.activate(options: []))
    let activationDeadline = Date().addingTimeInterval(5)
    while Date() < activationDeadline {
        if app.isActive,
           try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground",
           try messagesDockSnapshot().running == baseline.running + 1 { break }
        pumpSmokeRunLoop(for: 0.05)
    }
    try #require(app.isActive)
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    let activatedDock = try messagesDockSnapshot()
    #expect(activatedDock.running == baseline.running + 1)
    #expect(activatedDock.tiles >= max(1, baseline.tiles))

    try runSmokeWorker {
        defer { controller.finishedAutomation() }
        try controller.prepareForAutomation()
    }
    #expect(app.isActive)
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    #expect(try messagesDockSnapshot().running == baseline.running + 1)

    let otherApp = try #require(previousFrontmost ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    try #require(otherApp.activate(options: []))
    let deactivationDeadline = Date().addingTimeInterval(5)
    while app.isActive && Date() < deactivationDeadline { pumpSmokeRunLoop(for: 0.05) }
    try #require(!app.isActive)
    pumpSmokeRunLoop(for: 0.5)
    try runSmokeWorker {
        defer { controller.finishedAutomation() }
        try controller.prepareForAutomation()
    }
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
    let dockDeadline = Date().addingTimeInterval(5)
    while Date() < dockDeadline {
        let snapshot = try messagesDockSnapshot()
        if snapshot.tiles == baseline.tiles, snapshot.running == baseline.running { break }
        pumpSmokeRunLoop(for: 0.05)
    }
    let suppressedDock = try messagesDockSnapshot()
    #expect(suppressedDock.tiles == baseline.tiles)
    #expect(suppressedDock.running == baseline.running)
}
// swiftlint:enable no_magic_numbers
