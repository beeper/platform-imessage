import AppKit
import AccessibilityControl
import ApplicationServices
import IMessagePrivateSPI
import Testing
import WindowControl
@testable import IMessage

private func isWindowOnVisibleDesktop(_ window: UInt32) -> Bool {
    guard let membership = IMPrivateSPISpacesForWindow(window), !membership.isEmpty,
          let topology = IMPrivateSPICopyManagedDisplaySpaces() else { return false }
    let visibleSpaces = topology.compactMap { record -> UInt64? in
        guard let current = record["Current Space"] as? [String: Any] else { return nil }
        return (current["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (current["id64"] as? NSNumber)?.uint64Value
    }
    return membership.allSatisfy {
        visibleSpaces.contains($0.uint64Value) || $0.uint64Value == IMPrivateSPIActiveSpace()
    }
}

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
    defer {
        if let previousFrontmost {
            NSRunningApplication(processIdentifier: previousFrontmost.processIdentifier)?.activate(options: [.activateAllWindows])
        }
    }
    let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).map(\.processIdentifier))
    let baseline = try messagesDockSnapshot()
    let controller = try runSmokeWorker {
        try await MessagesController(reportErrorMessage: { Issue.record(Comment(rawValue: $0)) })
    }
    defer { controller.dispose() }
    let app = try #require(NSRunningApplication(processIdentifier: try controller.elements.app.pid()))
    try #require(!existingPIDs.contains(app.processIdentifier))
    let usesBridge = try getBestWindowCoordinator() is BridgedSpacesWindowCoordinator
    // Follow the AX-confirmed main window, not the first wide CG surface:
    // Messages also owns wide menu-bar and unnamed internal windows.
    let window = try runSmokeWorker { try await controller.elements.mainWindow.window().raw }
    let idleSpace = IMPrivateSPISpacesForWindow(window)?.first?.uint64Value
    if usesBridge {
        #expect(idleSpace != nil && !isWindowOnVisibleDesktop(window))
        #expect(try !Accessibility.Element(pid: app.processIdentifier).isHidden())
        let parked = try #require(idleSpace.flatMap { Space(raw: .init($0)) })
        #expect(try parked.kind() == .unknown)
        #expect((try parked.values() as NSDictionary)["ManagedSpaceID"] == nil)
        #expect(try !Window.listDescriptions(.onScreen).contains { $0.owner == app.processIdentifier })
    }
    // Launch-returned NSRunningApplication objects can retain stale isActive values.
    // Query a fresh process object for each lifecycle assertion.
    func isTargetActive() -> Bool {
        let name = Accessibility.Attribute<Bool>.Name(kAXFrontmostAttribute)
        return (try? Accessibility.Element(pid: app.processIdentifier).attribute(name)()) ?? false
    }
    // Prove activation restores a suppressed instance through the lifecycle observer.
    try #require(!isTargetActive())
    try #require(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
    // Let lifecycle observation finish starting before testing user activation.
    pumpSmokeRunLoop(for: 1)
    let activationDesktop = IMPrivateSPIActiveSpace()
    try #require(app.activate(options: []))
    let activationDeadline = Date().addingTimeInterval(5)
    while Date() < activationDeadline {
        if isTargetActive(),
           try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground",
           try messagesDockSnapshot().running == baseline.running + 1,
           !usesBridge || isWindowOnVisibleDesktop(window) { break }
        pumpSmokeRunLoop(for: 0.05)
    }
    try #require(isTargetActive())
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    if usesBridge {
        #expect(isWindowOnVisibleDesktop(window))
        #expect(try Window.listDescriptions(.onScreen).contains { $0.window.raw == window })
        // Wait beyond the initial activation for a queued Dock Space switch.
        pumpSmokeRunLoop(for: 1)
        #expect(IMPrivateSPIActiveSpace() == activationDesktop)
        #expect(try Window.listDescriptions(.onScreen).contains { $0.window.raw == window })
    }
    let activatedDock = try messagesDockSnapshot()
    #expect(activatedDock.running == baseline.running + 1)
    #expect(activatedDock.tiles >= max(1, baseline.tiles))

    try runSmokeWorker {
        try await controller.withAutomation { () async throws -> Void in
        }
    }
    #expect(isTargetActive())
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    #expect(try messagesDockSnapshot().running == baseline.running + 1)

    let otherApp = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    try #require(otherApp.activate(options: []))
    let deactivationDeadline = Date().addingTimeInterval(5)
    while isTargetActive() && Date() < deactivationDeadline { pumpSmokeRunLoop(for: 0.05) }
    try #require(!isTargetActive())
    pumpSmokeRunLoop(for: 0.5)
    try runSmokeWorker {
        try await controller.withAutomation { () async throws -> Void in
            if usesBridge {
                #expect(!isWindowOnVisibleDesktop(window))
                #expect(try !Window.listDescriptions(.onScreen).contains { $0.window.raw == window })
            }
        }
    }
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
    if usesBridge {
        let restored = IMPrivateSPISpacesForWindow(window)?.first?.uint64Value
        #expect(restored == idleSpace && !isWindowOnVisibleDesktop(window))
        #expect(try !Accessibility.Element(pid: app.processIdentifier).isHidden())
        #expect(try runSmokeWorker { try await controller.elements.mainWindow.window().raw } == window)
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

    // Reopening after another background automation must work on the first
    // activation too, with the window remaining visible after Dock settles.
    try #require(app.activate(options: []))
    let reopenDeadline = Date().addingTimeInterval(5)
    while Date() < reopenDeadline {
        if isTargetActive(),
           try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground",
           try Window.listDescriptions(.onScreen).contains(where: { $0.window.raw == window }) { break }
        pumpSmokeRunLoop(for: 0.05)
    }
    pumpSmokeRunLoop(for: 1)
    #expect(isTargetActive())
    #expect(IMPrivateSPIActiveSpace() == activationDesktop)
    #expect(try Window.listDescriptions(.onScreen).contains { $0.window.raw == window })

    // Activate during automation while the window is parked. Completion keeps
    // idle windows in the unknown Space; activation must reveal on the desktop.
    try #require(otherApp.activate(options: []))
    let interruptedDeadline = Date().addingTimeInterval(5)
    while isTargetActive() && Date() < interruptedDeadline { pumpSmokeRunLoop(for: 0.05) }
    try #require(!isTargetActive())
    pumpSmokeRunLoop(for: 0.5)
    try runSmokeWorker {
        try await controller.withAutomation { () async throws -> Void in
            try #require(app.activate(options: []))
            let deadline = Date().addingTimeInterval(5)
            let frontmost = Accessibility.Attribute<Bool>.Name(kAXFrontmostAttribute)
            let target = Accessibility.Element(pid: app.processIdentifier)
            while Date() < deadline {
                if try target.attribute(frontmost)(),
                   try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground",
                   try Window.listDescriptions(.onScreen).contains(where: { $0.window.raw == window }) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            try #require(try target.attribute(frontmost)())
            #expect(try Window.listDescriptions(.onScreen).contains { $0.window.raw == window })
        }
    }
    pumpSmokeRunLoop(for: 1)
    #expect(isTargetActive())
    #expect(isWindowOnVisibleDesktop(window))
    #expect(try Window.listDescriptions(.onScreen).contains { $0.window.raw == window })
}
