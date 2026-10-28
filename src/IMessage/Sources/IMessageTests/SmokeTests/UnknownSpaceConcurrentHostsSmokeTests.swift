import AppKit
import AccessibilityControl
import ApplicationServices
import Darwin
import IMessageCore
import IMessagePrivateSPI
import Testing
import WindowControl
@testable import IMessage

/// Exercises independent production controllers, including host disposal and
/// native activation through their lifecycle observers.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_UNKNOWN_SPACE_CONCURRENT_SMOKE"] == "1"))
@MainActor
func unknownSpaceConcurrentHostsSmoke() throws {
    try #require(AXIsProcessTrusted())
    Defaults.registerDefaults()
    try #require(Defaults.shouldCoordinateWindow)
    let originalSecondary = Preferences.useSecondaryMessagesInstance
    Preferences.useSecondaryMessagesInstance = true
    defer { Preferences.useSecondaryMessagesInstance = originalSecondary }
    let previous = NSWorkspace.shared.frontmostApplication
    defer {
        if let previous {
            NSRunningApplication(processIdentifier: previous.processIdentifier)?.activate(options: [.activateAllWindows])
        }
    }
    let managedBefore = try smokeManagedSpaceIDs()
    let currentBefore = try smokeManagedSpaceIDs(currentOnly: true)
    let existingPIDs = smokeMessagesPIDs()
    let first = try concurrentLaunchParkedFixture()
    defer { concurrentCleanUp(first) }
    let second = try concurrentLaunchParkedFixture()
    defer { concurrentCleanUp(second) }
    try #require(first.app.processIdentifier != second.app.processIdentifier)
    let parking = try #require(try smokeWindowSpaces(first.window).first)
    #expect(try smokeWindowSpaces(first.window) == [parking])
    #expect(try smokeWindowSpaces(second.window) == [parking])
    let space = try #require(Space(raw: .init(parking)))
    #expect(try space.kind() == .unknown)
    let values = try space.values() as NSDictionary
    #expect(values["ManagedSpaceID"] == nil)
    #expect(values["uuid"] as? String == PersistentUnknownSpace.uuid)
    #expect(try smokePoolSpaceIDs() == Set([parking]))
    #expect(try smokeManagedSpaceIDs() == managedBefore)
    try smokeAssertParkedAX(elements: first.elements, window: first.window, parking: parking)
    try smokeAssertParkedAX(elements: second.elements, window: second.window, parking: parking)

    // Primary selection must reject ambiguity without touching either host.
    #expect(throws: ErrorMessage.self) {
        try MessagesInstanceTarget.primaryInstance(in: [first.app, second.app])
    }
    #expect(smokeMessagesPIDs() == existingPIDs.union([first.app.processIdentifier, second.app.processIdentifier]))
    try smokeAssertParkedAX(elements: first.elements, window: first.window, parking: parking)
    try smokeAssertParkedAX(elements: second.elements, window: second.window, parking: parking)

    // A competing host must fail before hiding or moving the borrowed process.
    let competitor = try BridgedSpacesWindowCoordinator()
    competitor.app = first.app
    defer { try? competitor.dispose() }
    try runSmokeWorker {
        do {
            try competitor.prepareAfterLaunch()
            Issue.record("A coordinator already owns this Messages PID")
        } catch WindowCoordinatorError.instanceInUse {
            // Require the dedicated contention error, rather than any failure.
        }
    }
    try smokeAssertParkedAX(elements: first.elements, window: first.window, parking: parking)
    try smokeAssertParkedAX(elements: second.elements, window: second.window, parking: parking)

    // Actual host exit terminates its owned app before coordinator restoration.
    // It must leave the other host's process and parked windows untouched.
    try runSmokeWorker { first.controller.dispose() }
    try waitForSmoke("first Messages process and window exit") {
        guard smokeProcessExited(first.app.processIdentifier) else { return false }
        return try !Window.listDescriptions(.all).contains {
            $0.owner == first.app.processIdentifier || $0.window.raw == first.window
        }
    }
    #expect(try !Window.listDescriptions(.all).contains { $0.owner == first.app.processIdentifier || $0.window.raw == first.window })
    #expect(try !smokeOnscreen(first.window))
    #expect(smokeMessagesPIDs() == existingPIDs.union([second.app.processIdentifier]))
    #expect(try smokePoolSpaceIDs() == Set([parking]))
    #expect(try smokeManagedSpaceIDs() == managedBefore)
    try smokeAssertParkedAX(elements: second.elements, window: second.window, parking: parking)

    // Let observer startup finish, then use native activation only. The
    // production lifecycle callback must restore Dock presence and reveal.
    pumpSmokeRunLoop(for: 1)
    let activationDesktop = IMPrivateSPIActiveSpace()
    try #require(second.app.activate(options: [.activateAllWindows]))
    try waitForSmoke("second Messages activation and reveal") {
        try smokeFrontmost(second.elements.app) && smokeOnscreen(second.window) &&
            !smokeWindowSpaces(second.window).contains(parking)
    }
    let revealed = try smokeWindowSpaces(second.window)
    #expect(revealed.count == 1 && revealed.allSatisfy { currentBefore.contains($0) })
    #expect(!revealed.contains(parking))
    pumpSmokeRunLoop(for: 1)
    #expect(try smokeFrontmost(second.elements.app))
    #expect(try smokeOnscreen(second.window))
    #expect(IMPrivateSPIActiveSpace() == activationDesktop)
    #expect(IMPrivateSPIActiveSpace() != parking)
    #expect(smokeProcessExited(first.app.processIdentifier))
    #expect(try !Window.listDescriptions(.all).contains { $0.owner == first.app.processIdentifier || $0.window.raw == first.window })
    #expect(smokeMessagesPIDs() == existingPIDs.union([second.app.processIdentifier]))
    #expect(try smokePoolSpaceIDs() == Set([parking]))
    #expect(try smokeManagedSpaceIDs() == managedBefore)
    #expect(try smokeManagedSpaceIDs(currentOnly: true) == currentBefore)
    print("UNKNOWN_SPACE_CONCURRENT_SUMMARY launcherPID=\(getpid()) space=\(parking) firstPID=\(first.app.processIdentifier) secondPID=\(second.app.processIdentifier) contention=instanceInUse")
    fflush(nil)
}

private struct ConcurrentParkedFixture {
    let controller: MessagesController
    let app: NSRunningApplication
    let elements: MessagesAppElements
    let window: UInt32
}

@MainActor
private func concurrentLaunchParkedFixture() throws -> ConcurrentParkedFixture {
    let existing = smokeMessagesPIDs()
    let coordinator = try BridgedSpacesWindowCoordinator()
    let controller = try runSmokeWorker {
        try MessagesController(windowCoordinator: coordinator, reportErrorMessage: { Issue.record(Comment(rawValue: $0)) })
    }
    var ready = false
    defer {
        if !ready { controller.dispose() }
    }
    let app = try #require(NSRunningApplication(processIdentifier: try controller.elements.app.pid()))
    try #require(!existing.contains(app.processIdentifier))
    let elements = controller.elements
    try #require(try !smokeFrontmost(elements.app))
    let main = try #require(elements.getMainWindow(), "Parking must expose the existing main window through AX")
    let window = try main.window().raw
    ready = true
    return ConcurrentParkedFixture(controller: controller, app: app, elements: elements, window: window)
}

@MainActor
private func concurrentCleanUp(_ fixture: ConcurrentParkedFixture) {
    try? runSmokeWorker { fixture.controller.dispose() }
}
