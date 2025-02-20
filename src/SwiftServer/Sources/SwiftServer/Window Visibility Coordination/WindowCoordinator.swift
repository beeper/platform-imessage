import Cocoa
import AccessibilityControl
import Logging

private let log = Logger(swiftServerLabel: "window-coordinator")

/**
 * An abstraction over a way to make the Messages app automatable for short periods of time.
 */
protocol WindowCoordinator {
    /** The application to coordinate. */
    var app: NSRunningApplication? { get set }

    /** Specifies whether the coordinator is okay with reusing an instance of Messages that was already open. */
    var canReuseExtantInstance: Bool { get }

    /** Manipulates the Messages window in such a way that it becomes controllable via Accessibility APIs. */
    func makeAutomatable(_ window: Accessibility.Element) throws

    /** Signals to the coordinator that automation has completed; if desired, it may now e.g. hide the window. */
    func automationDidComplete(_ window: Accessibility.Element) throws

    /** Reverts the manipulations performed in `makeAutomatable`. */
    func reset(_ window: Accessibility.Element) throws

    /** Called when the user manually activates the app. `reset` is also called in this case. */
    func userManuallyActivated(_ app: NSRunningApplication) throws

    /** Called when the user finishes manual control over the app. */
    func userManuallyDeactivated(_ app: NSRunningApplication) throws
}

extension WindowCoordinator {
    func userManuallyActivated(_ app: NSRunningApplication) throws {
        // make this method optional
    }

    func userManuallyDeactivated(_ app: NSRunningApplication) throws {
        // make this method optional
    }
}

extension WindowCoordinator {
    static var shouldCoordinate: Bool { Defaults.swiftServer.bool(forKey: DefaultsKeys.windowCoordination) }

    func automate<T>(window: Accessibility.Element, _ automation: () throws -> T) throws -> T {
        try makeAutomatable(window)
        defer {
            do {
                try automationDidComplete(window)
            } catch {
                log.error("automationDidComplete errored: \(String(reflecting: error))")
            }
        }

        return try automation()
    }
}

enum WindowCoordinatorError: Error {
    case generic(message: String)
}

func getBestWindowCoordinator() -> any WindowCoordinator {
    EclipsingWindowCoordinator()
}
