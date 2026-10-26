import AppKit
import AccessibilityControl
import ApplicationServices
import Darwin
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
    let managedBefore = try concurrentManagedSpaces()
    let currentBefore = try concurrentManagedSpaces(currentOnly: true)
    let existingPIDs = concurrentMessagesPIDs()
    let first = try concurrentLaunchParkedFixture()
    defer { concurrentCleanUp(first) }
    let second = try concurrentLaunchParkedFixture()
    defer { concurrentCleanUp(second) }
    try #require(first.app.processIdentifier != second.app.processIdentifier)
    let parking = try #require(try concurrentMembership(first.window).first)
    #expect(try concurrentMembership(first.window) == [parking])
    #expect(try concurrentMembership(second.window) == [parking])
    let space = try #require(Space(raw: .init(parking)))
    #expect(try space.kind() == .unknown)
    let values = try space.values() as NSDictionary
    #expect(values["ManagedSpaceID"] == nil)
    #expect(values["uuid"] as? String == PersistentUnknownSpace.uuid)
    #expect(try concurrentPoolIDs() == Set([parking]))
    #expect(try concurrentManagedSpaces() == managedBefore)
    try concurrentAssertParkedAX(first, parking: parking)
    try concurrentAssertParkedAX(second, parking: parking)

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
    try concurrentAssertParkedAX(first, parking: parking)
    try concurrentAssertParkedAX(second, parking: parking)

    // Actual host exit terminates its owned app before coordinator restoration.
    // It must leave the other host's process and parked windows untouched.
    try runSmokeWorker { first.controller.dispose() }
    try concurrentWait("first Messages process and window exit") {
        guard concurrentProcessExited(first.app.processIdentifier) else { return false }
        return try !Window.listDescriptions(.all).contains {
            $0.owner == first.app.processIdentifier || $0.window.raw == first.window
        }
    }
    #expect(try !Window.listDescriptions(.all).contains { $0.owner == first.app.processIdentifier || $0.window.raw == first.window })
    #expect(try !concurrentOnscreen(first.window))
    #expect(concurrentMessagesPIDs() == existingPIDs.union([second.app.processIdentifier]))
    #expect(try concurrentPoolIDs() == Set([parking]))
    #expect(try concurrentManagedSpaces() == managedBefore)
    try concurrentAssertParkedAX(second, parking: parking)

    // Let observer startup finish, then use native activation only. The
    // production lifecycle callback must restore Dock presence and reveal.
    pumpSmokeRunLoop(for: 1)
    let activationDesktop = IMPrivateSPIActiveSpace()
    try #require(second.app.activate(options: [.activateAllWindows]))
    try concurrentWait("second Messages activation and reveal") {
        try concurrentFrontmost(second.elements.app) && concurrentOnscreen(second.window) &&
            !concurrentMembership(second.window).contains(parking)
    }
    let revealed = try concurrentMembership(second.window)
    #expect(revealed.count == 1 && revealed.allSatisfy { currentBefore.contains($0) })
    #expect(!revealed.contains(parking))
    pumpSmokeRunLoop(for: 1)
    #expect(try concurrentFrontmost(second.elements.app))
    #expect(try concurrentOnscreen(second.window))
    #expect(IMPrivateSPIActiveSpace() == activationDesktop)
    #expect(IMPrivateSPIActiveSpace() != parking)
    #expect(concurrentProcessExited(first.app.processIdentifier))
    #expect(try !Window.listDescriptions(.all).contains { $0.owner == first.app.processIdentifier || $0.window.raw == first.window })
    #expect(concurrentMessagesPIDs() == existingPIDs.union([second.app.processIdentifier]))
    #expect(try concurrentPoolIDs() == Set([parking]))
    #expect(try concurrentManagedSpaces() == managedBefore)
    #expect(try concurrentManagedSpaces(currentOnly: true) == currentBefore)
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
    let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).map(\.processIdentifier))
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
    try #require(try !concurrentFrontmost(elements.app))
    let main = try #require(elements.getMainWindow(), "Parking must expose the existing main window through AX")
    let window = try main.window().raw
    ready = true
    return ConcurrentParkedFixture(controller: controller, app: app, elements: elements, window: window)
}

@MainActor
private func concurrentCleanUp(_ fixture: ConcurrentParkedFixture) {
    try? runSmokeWorker { fixture.controller.dispose() }
}

@MainActor
private func concurrentAssertParkedAX(_ fixture: ConcurrentParkedFixture, parking: UInt64) throws {
    #expect(try concurrentMembership(fixture.window) == [parking])
    #expect(try !fixture.elements.app.isHidden())
    #expect(try !concurrentOnscreen(fixture.window))
    let main = try #require(fixture.elements.getMainWindow())
    #expect(try main.window().raw == fixture.window)
    let search = try fixture.elements.searchField
    let original = try #require(try search.value() as? String)
    defer { try? search.value(assign: original) }
    let query = "Beeper concurrent parking \(UUID().uuidString)"
    try search.value(assign: query)
    try concurrentWait("parked AX write/read") { try search.value() as? String == query }
    try search.value(assign: original)
    #expect(try search.value() as? String == original)
}

private func concurrentMembership(_ window: UInt32) throws -> [UInt64] {
    try #require(IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value))
}

private func concurrentOnscreen(_ window: UInt32) throws -> Bool {
    try Window.listDescriptions(.onScreen).contains { $0.window.raw == window }
}

private func concurrentFrontmost(_ app: Accessibility.Element) throws -> Bool {
    try app.attribute(Accessibility.Attribute<Bool>.Name(kAXFrontmostAttribute))()
}

private func concurrentPoolIDs() throws -> Set<UInt64> {
    var result = Set<UInt64>()
    for space in try Space.list(.allOSSpaces) {
        guard try space.kind() == .unknown else { continue }
        let values = try space.values() as NSDictionary
        if values["uuid"] as? String == PersistentUnknownSpace.uuid {
            #expect(values["ManagedSpaceID"] == nil)
            result.insert(UInt64(space.raw))
        }
    }
    return result
}

private func concurrentManagedSpaces(currentOnly: Bool = false) throws -> Set<UInt64> {
    let topology = try #require(IMPrivateSPICopyManagedDisplaySpaces())
    try #require(!topology.isEmpty)
    return Set(topology.flatMap { record -> [UInt64] in
        let current = (record["Current Space"] as? [String: Any]).map { [$0] } ?? []
        let spaces = currentOnly ? current : (record["Spaces"] as? [[String: Any]] ?? []) + current
        return spaces.compactMap {
            ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? ($0["id64"] as? NSNumber)?.uint64Value
        }
    })
}

private func concurrentMessagesPIDs() -> Set<pid_t> {
    Set(NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).map(\.processIdentifier))
}

private func concurrentProcessExited(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

@MainActor
private func concurrentWait(_ description: String, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if try condition() { return }
        pumpSmokeRunLoop(for: 0.02)
    }
    try #require(try condition(), Comment(rawValue: "Timed out waiting for \(description)"))
}
