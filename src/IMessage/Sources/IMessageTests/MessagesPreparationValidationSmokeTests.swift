import AppKit
import AccessibilityControl
import ApplicationServices
import Carbon.HIToolbox.Events
import IMessagePrivateSPI
import Testing
import WindowControl
@testable import IMessage

private enum PreparationStage: CaseIterable {
    case beforeWindowDiscovery
    case afterWindowDiscovery
}

private enum InjectedPreparationFailure: Error {
    case expected
}

/// Injects a one-shot failure while preserving the real launch, parking, and
/// cleanup lifecycle. Failure injection and recovery run on the same worker.
private final class FailingPreparationCoordinator: WindowCoordinator {
    let wrapped: BridgedSpacesWindowCoordinator
    var failAt: PreparationStage?
    var app: NSRunningApplication? {
        get { wrapped.app }
        set { wrapped.app = newValue }
    }
    var canReuseExtantInstance: Bool { wrapped.canReuseExtantInstance }

    init() throws { wrapped = try BridgedSpacesWindowCoordinator() }

    private func injectFailure(at stage: PreparationStage) throws {
        if failAt == stage {
            failAt = nil
            throw InjectedPreparationFailure.expected
        }
    }

    func prepareAfterLaunch() throws { try wrapped.prepareAfterLaunch() }
    func prepareForAutomation() throws {
        try injectFailure(at: .beforeWindowDiscovery)
        try wrapped.prepareForAutomation()
    }
    func makeAutomatable(_ window: Accessibility.Element) throws {
        try injectFailure(at: .afterWindowDiscovery)
        try wrapped.makeAutomatable(window)
    }
    func automationDidComplete(_ window: Accessibility.Element) throws { try wrapped.automationDidComplete(window) }
    func reset(_ window: Accessibility.Element) throws { try wrapped.reset(window) }
    func userManuallyActivated(_ app: NSRunningApplication) throws { try wrapped.userManuallyActivated(app) }
    func userManuallyDeactivated(_ app: NSRunningApplication) throws { try wrapped.userManuallyDeactivated(app) }
    func dispose() throws { try wrapped.dispose() }
}

// Each test launches and closes its own secondary Messages instance. Serialize
// desktop interactions; neither test sends messages or changes account settings.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_PREPARATION_VALIDATION_SMOKE"] == "1"))
@MainActor
struct MessagesPreparationValidationSmokeTests {
    @Test
    func preparationFailureDoesNotPoisonActivityLock() throws {
        try #require(AXIsProcessTrusted())
        Defaults.registerDefaults()
        try #require(Defaults.shouldCoordinateWindow)
        let originalSecondary = Preferences.useSecondaryMessagesInstance
        Preferences.useSecondaryMessagesInstance = true
        defer { Preferences.useSecondaryMessagesInstance = originalSecondary }
        let previous = NSWorkspace.shared.frontmostApplication
        defer { restoreFrontmost(previous) }
        let coordinator = try FailingPreparationCoordinator()
        let controller = try runSmokeWorker {
            try MessagesController(windowCoordinator: coordinator, reportErrorMessage: { Issue.record(Comment(rawValue: $0)) })
        }
        defer { controller.dispose() }

        try runSmokeWorker {
            for stage in PreparationStage.allCases {
                coordinator.failAt = stage
                var caughtInjectedFailure = false
                do {
                    try controller.prepareForAutomation()
                    // Clean up even if the expected failure point was skipped.
                    controller.finishedAutomation()
                } catch InjectedPreparationFailure.expected {
                    caughtInjectedFailure = true
                }
                try #require(caughtInjectedFailure, "The requested failure must actually be thrown")
                try #require(coordinator.failAt == nil, "The requested failure point must actually be reached")
                // With the old defer-based acquisition this re-enters an unfair
                // lock still owned by this thread and aborts instead of succeeding.
                try controller.prepareForAutomation()
                controller.finishedAutomation()
            }
        }
        #expect(try !controller.elements.app.isHidden())
        let recoveredWindow = try controller.elements.mainWindow.window().raw
        #expect(try !isOnscreen(recoveredWindow))
        let recoveredSpaceID = try #require(IMPrivateSPISpacesForWindow(recoveredWindow)?.first?.uint64Value)
        let recoveredSpace = try #require(Space(raw: .init(recoveredSpaceID)))
        #expect(try recoveredSpace.kind() == .unknown)
    }

    @Test
    func largerSettingsWindowDoesNotExposeMainWindow() throws {
        try #require(AXIsProcessTrusted())
        Defaults.registerDefaults()
        let previous = NSWorkspace.shared.frontmostApplication
        defer { restoreFrontmost(previous) }
        let coordinator = try BridgedSpacesWindowCoordinator()
        let app = try runSmokeWorker {
            try MessagesInstanceTarget.launchSecondaryInstance(
                initialDeepLink: MessagesDeepLink.compose.url(), activating: true
            )
        }
        defer {
            try? coordinator.dispose()
            app.terminate()
        }
        let axApp = Accessibility.Element(pid: app.processIdentifier)
        try waitFor { try isFrontmost(axApp) }
        coordinator.app = app
        let elements = MessagesAppElements(runningApp: app)
        let main = try elements.mainWindow
        let mainID = try main.window().raw
        let originalMainFrame = try main.frame()
        defer { try? main.setFrame(originalMainFrame) }
        // Record the AX-confirmed main window while the user controls the app.
        try coordinator.makeAutomatable(main)
        let existing = Set(try axApp.appWindows().compactMap { try? $0.window().raw })
        for down in [true, false] {
            let event = try #require(CGEvent(keyboardEventSource: KeyPresser.src, virtualKey: CGKeyCode(kVK_ANSI_Comma), keyDown: down))
            event.flags = .maskCommand
            event.postToPid(app.processIdentifier)
        }
        var settings: Accessibility.Element?
        try waitFor {
            settings = try axApp.appWindows().first {
                guard let id = try? $0.window().raw else { return false }
                return !existing.contains(id)
            }
            return settings != nil
        }
        let settingsWindow = try #require(settings, "Command-comma must open a new Settings window")
        let settingsID = try settingsWindow.window().raw
        let originalSettingsFrame = try settingsWindow.frame()
        defer {
            try? settingsWindow.setFrame(originalSettingsFrame)
            try? settingsWindow.closeWindow()
        }
        // Do not assume AX accepted a resize: compare the actual resulting sizes.
        try main.setFrame(CGRect(x: originalMainFrame.minX, y: originalMainFrame.minY, width: 400, height: 300))
        if try settingsWindow.size.isSettable() {
            try settingsWindow.setFrame(CGRect(x: originalSettingsFrame.minX, y: originalSettingsFrame.minY, width: 1100, height: 900))
        }
        let mainFrame = try main.frame()
        let settingsFrame = try settingsWindow.frame()
        try #require(settingsFrame.width * settingsFrame.height > mainFrame.width * mainFrame.height,
                     "Settings must really be larger than the main window")
        print("LARGER_SETTINGS main=\(mainFrame.size) settings=\(settingsFrame.size)")
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        try #require(finder.activate(options: []))
        try waitFor { try !isFrontmost(axApp) }
        try MessagesDockSuppression.suppress(app)
        app.hide()
        try waitFor { try axApp.isHidden() }
        let originalMainSpaces = IMPrivateSPISpacesForWindow(mainID)?.map(\.uint64Value)
        let originalSettingsSpaces = IMPrivateSPISpacesForWindow(settingsID)?.map(\.uint64Value)
        try #require(try !isOnscreen(mainID) && !isOnscreen(settingsID))

        var exposures = Set<UInt32>()
        var samples = 0
        var samplingErrors = 0
        let sampler = Timer(timeInterval: 0.005, repeats: true) { _ in
            do {
                let visible = try Window.listDescriptions(.onScreen)
                samples += 1
                for id in [mainID, settingsID] where visible.contains(where: { $0.window.raw == id }) {
                    exposures.insert(id)
                }
            } catch { samplingErrors += 1 }
        }
        RunLoop.main.add(sampler, forMode: .common)
        defer { sampler.invalidate() }
        try runSmokeWorker { try coordinator.prepareForAutomation() }
        sampler.invalidate()
        // This is checked before makeAutomatable(main), so the old code cannot
        // repair an exposed main window and mask its incorrect Settings choice.
        try #require(samples > 0 && samplingErrors == 0, "The visibility sampler must actually run without read failures")
        #expect(exposures.isEmpty, "Neither window may flash onscreen during preparation")
        #expect(try !isOnscreen(mainID) && !isOnscreen(settingsID))
        print("SETTINGS_CONCEALMENT samples=\(samples) exposures=\(exposures.count)")
        let parkedMain = try #require(IMPrivateSPISpacesForWindow(mainID)?.map(\.uint64Value))
        let parkedSettings = try #require(IMPrivateSPISpacesForWindow(settingsID)?.map(\.uint64Value))
        #expect(parkedMain.count == 1 && parkedMain == parkedSettings)
        #expect(parkedMain != originalMainSpaces && parkedSettings != originalSettingsSpaces)
        let parkedSpace = try #require(parkedMain.first.flatMap { Space(raw: .init($0)) })
        #expect(try parkedSpace.kind() == .unknown)
        #expect((try parkedSpace.values() as NSDictionary)["ManagedSpaceID"] == nil)
        try runSmokeWorker { try coordinator.automationDidComplete(main) }
        #expect(try !axApp.isHidden())
        #expect(try elements.mainWindow.window().raw == mainID)
        #expect(IMPrivateSPISpacesForWindow(mainID)?.map(\.uint64Value) == parkedMain)
        #expect(IMPrivateSPISpacesForWindow(settingsID)?.map(\.uint64Value) == parkedSettings)
        #expect(try !isOnscreen(mainID) && !isOnscreen(settingsID))

        // Manual activation must reveal both windows on their ordinary
        // desktop, rather than merely hiding them forever in the shared pool.
        try coordinator.restoreDockPresence()
        try #require(app.activate(options: [.activateAllWindows]))
        try waitFor { try isFrontmost(axApp) }
        try runSmokeWorker { try coordinator.userManuallyActivated(app) }
        try waitFor { try isOnscreen(mainID) && isOnscreen(settingsID) }
        #expect(IMPrivateSPISpacesForWindow(mainID)?.map(\.uint64Value) == originalMainSpaces)
        #expect(IMPrivateSPISpacesForWindow(settingsID)?.map(\.uint64Value) == originalSettingsSpaces)
    }

    private func waitFor(_ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try condition() { return }
            pumpSmokeRunLoop(for: 0.02)
        }
        try #require(try condition(), "Timed out waiting for live Messages state")
    }

    private func restoreFrontmost(_ app: NSRunningApplication?) {
        if let app { NSRunningApplication(processIdentifier: app.processIdentifier)?.activate(options: [.activateAllWindows]) }
    }
}

private func isFrontmost(_ app: Accessibility.Element) throws -> Bool {
    try app.attribute(Accessibility.Attribute<Bool>.Name(kAXFrontmostAttribute))()
}

private func isOnscreen(_ id: UInt32) throws -> Bool {
    try Window.listDescriptions(.onScreen).contains { $0.window.raw == id }
}
