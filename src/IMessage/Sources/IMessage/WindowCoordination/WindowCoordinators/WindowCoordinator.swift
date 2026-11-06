import Cocoa
import AccessibilityControl

/// Coordinates Messages windows during automation and manual use.
protocol WindowCoordinator: AnyObject {
    @MainActor
    var app: NSRunningApplication? { get set }

    /// Keep blocking AX/window-server calls off the main actor; hop to it for AppKit state.
    func makeAutomatable(_ window: Accessibility.Element) async throws
    func prepareForAutomation() throws
    func prepareAfterLaunch() throws
    func dispose() throws

    /// Parks or hides windows after automation.
    func automationDidComplete() async throws

    /// Reverts window changes before handing control to the user.
    func reset(_ window: Accessibility.Element) async throws

    func userManuallyActivated(_ app: NSRunningApplication) async throws

    func userManuallyDeactivated(_ app: NSRunningApplication) async throws
}

extension WindowCoordinator {
    func prepareForAutomation() throws {}
    func prepareAfterLaunch() throws {}
    func dispose() throws {}

    @MainActor
    func suppressDockPresence() throws {
        if let app { try MessagesDockSuppression.suppress(app) }
    }

    @MainActor
    func restoreDockPresence() throws {
        if let app { try MessagesDockSuppression.restore(app) }
    }

    func userManuallyActivated(_: NSRunningApplication) throws {}

    func userManuallyDeactivated(_: NSRunningApplication) throws {}
}

enum WindowCoordinatorError: Error {
    case generic(message: String)
    case instanceInUse
}
