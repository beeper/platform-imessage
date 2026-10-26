import AppKit
import AccessibilityControl
import ApplicationServices
import Darwin
import IMessagePrivateSPI
import Testing
import WindowControl
@testable import IMessage

/// Each invocation uses three fresh secondary Messages processes and production
/// coordinators. Run this test in two independent runners to validate reuse after
/// the launcher process exits as well as after individual controllers dispose.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_UNKNOWN_SPACE_REUSE_SMOKE"] == "1"))
@MainActor
func secondaryMessagesUnknownSpaceReuseSmoke() throws {
    try #require(AXIsProcessTrusted(), "Unknown-Space reuse smoke requires Accessibility permission")
    try #require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow", "Unlock the Mac before running live Messages tests")
    Defaults.registerDefaults()
    try #require(Defaults.shouldCoordinateWindow && Defaults.dockSuppression)
    let originalSecondary = Preferences.useSecondaryMessagesInstance
    Preferences.useSecondaryMessagesInstance = true
    defer { Preferences.useSecondaryMessagesInstance = originalSecondary }
    let previousFrontmost = NSWorkspace.shared.frontmostApplication
    defer {
        if let previousFrontmost {
            NSRunningApplication(processIdentifier: previousFrontmost.processIdentifier)?.activate(options: [.activateAllWindows])
        }
    }
    let baselineManaged = try smokeManagedSpaceIDs()
    let baselineCurrent = try smokeManagedSpaceIDs(currentOnly: true)
    let initialPool = try smokePoolSpaceIDs()
    try #require(initialPool.count <= 1, "The reusable pool must not already contain duplicate matching unknown Spaces")
    var expectedSpace = initialPool.first
    var launchedPIDs = Set<pid_t>()
    for cycle in 1...3 {
        let result = try reuseControllerCycle(cycle: cycle, baselineManaged: baselineManaged, baselineCurrent: baselineCurrent)
        if let expectedSpace {
            #expect(result.space == expectedSpace, "Every controller must use the same retained unknown Space")
        } else {
            expectedSpace = result.space
        }
        #expect(launchedPIDs.insert(result.pid).inserted, "Each cycle must launch a new secondary Messages process")
        #expect(try smokePoolSpaceIDs() == Set([result.space]))
        #expect(try smokeManagedSpaceIDs() == baselineManaged)
        #expect(try smokeManagedSpaceIDs(currentOnly: true) == baselineCurrent)
    }
    let space = try #require(expectedSpace)
    print("UNKNOWN_SPACE_REUSE_SUMMARY launcherPID=\(getpid()) space=\(space) cycles=3")
    fflush(nil)
}

@MainActor
private func reuseControllerCycle(cycle: Int, baselineManaged: Set<UInt64>, baselineCurrent: Set<UInt64>) throws -> (space: UInt64, pid: pid_t) {
    let existingPIDs = smokeMessagesPIDs()
    let controller = try runSmokeWorker {
        try await MessagesController(reportErrorMessage: { Issue.record(Comment(rawValue: $0)) })
    }
    defer { controller.dispose() }
    let app = try #require(NSRunningApplication(processIdentifier: try controller.elements.app.pid()))
    try #require(!existingPIDs.contains(app.processIdentifier), "Only the new secondary process may be controlled")
    let main = try runSmokeWorker { try await controller.elements.mainWindow }
    let window = try main.window().raw
    let membership = try #require(IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value))
    try #require(membership.count == 1, "Idle Messages must belong exclusively to its parking Space")
    let parking = try #require(membership.first)
    let space = try #require(Space(raw: .init(parking)))
    #expect(try space.kind() == .unknown)
    let values = try space.values() as NSDictionary
    #expect(values["ManagedSpaceID"] == nil)
    #expect(values["uuid"] as? String == "Beeper-Unknown-Parking-v1-\(getuid())")
    #expect(!baselineManaged.contains(parking))
    #expect(try smokePoolSpaceIDs() == Set([parking]))
    #expect(try smokeManagedSpaceIDs() == baselineManaged)
    #expect(try smokeManagedSpaceIDs(currentOnly: true) == baselineCurrent)
    #expect(IMPrivateSPIActiveSpace() != parking)
    try reuseAssertParkedAX(controller: controller, window: window, parking: parking)
    // A second host must not move windows owned by this live coordinator.
    let competing = try BridgedSpacesWindowCoordinator()
    competing.app = app
    #expect(throws: (any Error).self) { try competing.prepareAfterLaunch() }
    #expect(IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value) == [parking])
    #expect(!app.isTerminated)

    // Activate through the production lifecycle observer. Unknown Spaces must
    // never become the selected desktop, and reveal must remove unknown membership.
    pumpSmokeRunLoop(for: 0.5)
    try #require(app.activate(options: [.activateAllWindows]))
    var stableSince: Date?
    try waitForSmoke("stable Messages activation and ordinary-desktop reveal") {
        let ready = try smokeFrontmost(controller.elements.app) && smokeOnscreen(window) &&
            !(IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value).contains(parking) ?? true) &&
            MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground"
        guard ready else {
            if stableSince != nil {
                let foreground = NSWorkspace.shared.frontmostApplication
                print("UNKNOWN_SPACE_ACTIVATION_SETTLING targetPID=\(app.processIdentifier) frontmostPID=\(foreground?.processIdentifier ?? 0) app=\(foreground?.bundleIdentifier ?? "nil")")
            }
            stableSince = nil
            return false
        }
        guard let stableSince else {
            stableSince = Date()
            return false
        }
        // Native activation, LS restoration, and the window move complete
        // asynchronously. Observe a settled handoff without issuing a retry.
        return Date().timeIntervalSince(stableSince) >= 0.5
    }
    let revealed = try #require(IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value))
    #expect(revealed.count == 1 && revealed.allSatisfy { baselineCurrent.contains($0) })
    pumpSmokeRunLoop(for: 0.5)
    let actualFrontmost = NSWorkspace.shared.frontmostApplication
    let presentation = try MessagesDockSuppression.applicationType(for: app.processIdentifier)
    #expect(try smokeFrontmost(controller.elements.app), Comment(rawValue:
        "Expected Messages PID \(app.processIdentifier); frontmost=\(actualFrontmost?.bundleIdentifier ?? "nil") PID=\(actualFrontmost?.processIdentifier ?? 0); presentation=\(presentation ?? "nil")"))
    #expect(try smokeOnscreen(window))
    #expect(IMPrivateSPIActiveSpace() != parking)
    #expect(try smokeManagedSpaceIDs(currentOnly: true) == baselineCurrent)

    let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    try #require(finder.activate(options: []))
    try waitForSmoke("Messages deactivation") { try !smokeFrontmost(controller.elements.app) }
    pumpSmokeRunLoop(for: 0.25)
    try runSmokeWorker {
        try await controller.withAutomation { () async throws -> Void in
            #expect(IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value) == [parking])
            #expect(try !smokeOnscreen(window))
        }
    }
    // Completion retains the unknown membership and leaves AX available.
    try reuseAssertParkedAX(controller: controller, window: window, parking: parking)
    var exitSamples = 0
    var exitSamplingErrors = 0
    var exitExposures = 0
    let exitSampler = Timer(timeInterval: 0.005, repeats: true) { _ in
        do {
            let visible = try smokeOnscreen(window)
            exitSamples += 1
            if visible { exitExposures += 1 }
        } catch { exitSamplingErrors += 1 }
    }
    RunLoop.main.add(exitSampler, forMode: .common)
    defer { exitSampler.invalidate() }
    try runSmokeWorker { controller.dispose() }
    exitSampler.invalidate()
    #expect(exitSamples > 0 && exitSamplingErrors == 0, "Exit visibility sampling must run without read failures")
    #expect(exitExposures == 0, "Quitting Messages must not expose its parked window")
    print("UNKNOWN_SPACE_EXIT_CONCEALMENT cycle=\(cycle) samples=\(exitSamples) exposures=\(exitExposures)")
    try waitForSmoke("secondary Messages process exit") {
        smokeProcessExited(app.processIdentifier)
    }
    #expect(try smokePoolSpaceIDs() == Set([parking]), "Disposal must retain the pool for a new controller")
    #expect(try smokeManagedSpaceIDs() == baselineManaged)
    #expect(try smokeManagedSpaceIDs(currentOnly: true) == baselineCurrent)
    print("UNKNOWN_SPACE_REUSE cycle=\(cycle) space=\(parking) secondaryPID=\(app.processIdentifier) managedCount=\(baselineManaged.count)")
    fflush(nil)
    return (parking, app.processIdentifier)
}

@MainActor
private func reuseAssertParkedAX(controller: MessagesController, window: UInt32, parking: UInt64) throws {
    #expect(IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value) == [parking])
    #expect(try !smokeOnscreen(window))
    #expect(try !controller.elements.app.isHidden())
    #expect(try runSmokeWorker { try await controller.elements.mainWindow.window().raw } == window)
    let search = try runSmokeWorker { try await controller.elements.searchField }
    let original = try #require(try search.value() as? String)
    defer { try? search.value(assign: original) }
    let query = "Beeper unknown Space reuse \(UUID().uuidString)"
    try search.value(assign: query)
    try waitForSmoke("AX search write/read while parked") { try search.value() as? String == query }
    try search.value(assign: original)
    #expect(try search.value() as? String == original)
}
