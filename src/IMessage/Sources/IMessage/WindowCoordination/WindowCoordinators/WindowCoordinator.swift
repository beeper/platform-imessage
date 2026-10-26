import Cocoa
import AccessibilityControl

/**
 * An abstraction over a way to make the Messages app automatable for short periods of time.
 */
protocol WindowCoordinator: AnyObject {
    /** The application to coordinate. */
    @MainActor
    var app: NSRunningApplication? { get set }

    /**
     * Manipulates the Messages window in such a way that it becomes controllable via Accessibility APIs.
     *
     * This is called right before the app needs to be automated.
     *
     * Intentionally NOT `@MainActor`: implementations perform blocking Accessibility/
     * window-server IPC that must stay off the main thread (an unresponsive Messages.app
     * would otherwise freeze the UI). Implementations hop to `@MainActor` only for the
     * AppKit reads they actually need.
     */
    func makeAutomatable(_ window: Accessibility.Element) async throws
    func prepareForAutomation() throws
    func prepareAfterLaunch() throws
    func dispose() throws

    /**
     * Signals to the coordinator that automation has completed; if desired, it may now e.g. hide the window.
     *
     * Takes no window argument: implementations don't need one, and passing the
     * non-`Sendable` `Accessibility.Element` to implementations that use the
     * main actor would be a concurrency violation.
     */
    func automationDidComplete() async throws

    /**
     * Reverts the manipulations performed in `makeAutomatable`.
     *
     * For example, this is called when the user manually activates the app. Coordination should quiesce until the user
     * resigns manual control.
     *
     * Not `@MainActor`, for the same reason as `makeAutomatable`.
     */
    func reset(_ window: Accessibility.Element) async throws

    /** Called when the user manually activates the app. `reset` is also called in this case. */
    @MainActor
    func userManuallyActivated(_ app: NSRunningApplication) throws

    /** Called when the user finishes manual control over the app. */
    @MainActor
    func userManuallyDeactivated(_ app: NSRunningApplication) throws
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

    @MainActor
    func userManuallyActivated(_: NSRunningApplication) throws {
        // make this method optional
    }

    @MainActor
    func userManuallyDeactivated(_: NSRunningApplication) throws {
        // make this method optional
    }
}

enum WindowCoordinatorError: Error {
    case generic(message: String)
    case instanceInUse
}
