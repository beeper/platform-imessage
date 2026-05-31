import Cocoa
import AccessibilityControl

/**
 * An abstraction over a way to make the Messages app automatable for short periods of time.
 */
protocol WindowCoordinator: AnyObject {
    /** The application to coordinate. */
    @MainActor
    var app: NSRunningApplication? { get set }

    /** Specifies whether the coordinator is okay with reusing an instance of Messages that was already open. */
    var canReuseExtantInstance: Bool { get }

    /**
     * Manipulates the Messages window in such a way that it becomes controllable via Accessibility APIs.
     *
     * This is called right before the app needs to be automated.
     */
    func makeAutomatable(_ window: Accessibility.Element) async throws

    /** Signals to the coordinator that automation has completed; if desired, it may now e.g. hide the window. */
    func automationDidComplete(_ window: Accessibility.Element) async throws

    /**
     * Reverts the manipulations performed in `makeAutomatable`.
     *
     * For example, this is called when the user manually activates the app. Coordination should quiesce until the user
     * resigns manual control.
     */
    func reset(_ window: Accessibility.Element) async throws

    /** Called when the user manually activates the app. `reset` is also called in this case. */
    func userManuallyActivated(_ app: NSRunningApplication) async throws

    /** Called when the user finishes manual control over the app. */
    func userManuallyDeactivated(_ app: NSRunningApplication) async throws
}

extension WindowCoordinator {
    func userManuallyActivated(_: NSRunningApplication) async throws {
        // make this method optional
    }

    func userManuallyDeactivated(_: NSRunningApplication) async throws {
        // make this method optional
    }
}

enum WindowCoordinatorError: Error {
    case generic(message: String)
}
