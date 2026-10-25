import AppKit
import ApplicationServices
import IMessagePrivateSPI
import Testing
import WindowControl
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
    let usesBridge = try getBestWindowCoordinator() is BridgedSpacesWindowCoordinator
    let launchSpace = IMPrivateSPIActiveSpace()
    let window = try #require(try Window.listDescriptions(.all).first {
        $0.owner == app.processIdentifier && $0.layer == 0 && $0.bounds.width > 300
    }).window.raw
    let hiddenSpace = IMPrivateSPISpacesForWindow(window)?.first?.uint64Value
    if usesBridge {
        #expect(hiddenSpace != nil && hiddenSpace != launchSpace)
        #expect(try !Window.listDescriptions(.onScreen).contains { $0.owner == app.processIdentifier })
    }
    // Launch-returned NSRunningApplication objects can retain stale isActive values.
    // Query a fresh process object for each lifecycle assertion.
    func isTargetActive() -> Bool {
        NSRunningApplication(processIdentifier: app.processIdentifier)?.isActive ?? false
    }
    // Prove activation restores a suppressed instance through the lifecycle observer.
    try #require(!isTargetActive())
    try #require(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
    // Let lifecycle observation finish starting before testing user activation.
    pumpSmokeRunLoop(for: 1)
    try #require(app.activate(options: []))
    let activationDeadline = Date().addingTimeInterval(5)
    while Date() < activationDeadline {
        if isTargetActive(),
           try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground",
           try messagesDockSnapshot().running == baseline.running + 1,
           !usesBridge || IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value) == [launchSpace] { break }
        pumpSmokeRunLoop(for: 0.05)
    }
    try #require(isTargetActive())
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    if usesBridge { #expect(IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value) == [launchSpace]) }
    let activatedDock = try messagesDockSnapshot()
    #expect(activatedDock.running == baseline.running + 1)
    #expect(activatedDock.tiles >= max(1, baseline.tiles))

    try runSmokeWorker {
        defer { controller.finishedAutomation() }
        try controller.prepareForAutomation()
    }
    #expect(isTargetActive())
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    #expect(try messagesDockSnapshot().running == baseline.running + 1)

    let otherApp = try #require(previousFrontmost ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    try #require(otherApp.activate(options: []))
    let deactivationDeadline = Date().addingTimeInterval(5)
    while isTargetActive() && Date() < deactivationDeadline { pumpSmokeRunLoop(for: 0.05) }
    try #require(!isTargetActive())
    pumpSmokeRunLoop(for: 0.5)
    try runSmokeWorker {
        defer { controller.finishedAutomation() }
        try controller.prepareForAutomation()
    }
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
    if usesBridge {
        #expect(IMPrivateSPISpacesForWindow(window)?.first?.uint64Value == hiddenSpace)
        #expect(try !Window.listDescriptions(.onScreen).contains { $0.owner == app.processIdentifier })
    }
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
