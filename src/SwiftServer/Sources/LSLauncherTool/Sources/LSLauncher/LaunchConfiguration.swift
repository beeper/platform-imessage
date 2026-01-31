import Foundation
import AppKit

// MARK: - Application Launch Mode

/// Represents the visibility mode of a macOS application
public enum ApplicationMode: String, CaseIterable, Sendable {
    /// Normal dock application with full UI
    case foreground = "Foreground"

    /// No dock icon, but can still display UI (menus, windows, etc.)
    case uiElement = "UIElement"

    /// No dock icon and no UI at all
    case backgroundOnly = "BackgroundOnly"

    public var description: String {
        switch self {
        case .foreground:
            return "Foreground (normal dock app)"
        case .uiElement:
            return "UIElement (no dock icon, can have UI)"
        case .backgroundOnly:
            return "Background (no dock icon, no UI)"
        }
    }

    /// Whether the application appears in the Dock
    public var showsInDock: Bool {
        self == .foreground
    }

    /// Whether the application can display UI
    public var canDisplayUI: Bool {
        self != .backgroundOnly
    }
}

// MARK: - Launch Configuration

/// Configuration options for launching an application
public struct LaunchConfiguration: Sendable {
    /// The visibility mode for the launched application
    public var mode: ApplicationMode

    /// Whether to activate (bring to front) the application after launch
    public var activate: Bool

    /// Whether to hide the application after launch
    public var hide: Bool

    /// Whether to wait for the application to finish launching before returning
    public var synchronous: Bool

    /// Whether to prefer reusing an already running instance
    public var preferRunningInstance: Bool

    /// Command-line arguments to pass to the application
    public var arguments: [String]?

    /// Environment variables to set for the application
    public var environment: [String: String]?

    /// Timeout for synchronous launches (in seconds)
    public var launchTimeout: TimeInterval

    /// Timeout for waiting for app to finish launching (in seconds)
    public var checkInTimeout: TimeInterval

    /// Whether to restore the application's previous state
    public var restoreState: Bool

    // MARK: - Initializers

    public init(
        mode: ApplicationMode = .foreground,
        activate: Bool = true,
        hide: Bool = false,
        synchronous: Bool = false,
        preferRunningInstance: Bool = true,
        arguments: [String]? = nil,
        environment: [String: String]? = nil,
        launchTimeout: TimeInterval = 30,
        checkInTimeout: TimeInterval = 60,
        restoreState: Bool = true
    ) {
        self.mode = mode
        self.activate = activate
        self.hide = hide
        self.synchronous = synchronous
        self.preferRunningInstance = preferRunningInstance
        self.arguments = arguments
        self.environment = environment
        self.launchTimeout = launchTimeout
        self.checkInTimeout = checkInTimeout
        self.restoreState = restoreState
    }

    // MARK: - Preset Configurations

    /// Default foreground launch configuration
    public static var `default`: LaunchConfiguration {
        LaunchConfiguration()
    }

    /// Launch as a background-only application (no dock, no UI)
    public static var background: LaunchConfiguration {
        LaunchConfiguration(
            mode: .backgroundOnly,
            activate: false,
            hide: true
        )
    }

    /// Launch as a UIElement (no dock icon, but can have UI)
    public static var uiElement: LaunchConfiguration {
        LaunchConfiguration(
            mode: .uiElement,
            activate: false
        )
    }

    /// Launch synchronously, waiting for the app to be fully ready
    public static var synchronous: LaunchConfiguration {
        LaunchConfiguration(synchronous: true)
    }

    /// Launch in background synchronously (suppressed app that's fully ready)
    public static var synchronousBackground: LaunchConfiguration {
        LaunchConfiguration(
            mode: .backgroundOnly,
            activate: false,
            hide: true,
            synchronous: true
        )
    }

    /// Launch as UIElement synchronously
    public static var synchronousUIElement: LaunchConfiguration {
        LaunchConfiguration(
            mode: .uiElement,
            activate: false,
            synchronous: true
        )
    }

    /// Launch hidden (foreground app but starts hidden)
    public static var hidden: LaunchConfiguration {
        LaunchConfiguration(
            activate: false,
            hide: true
        )
    }

    /// Launch fresh without restoring state
    public static var fresh: LaunchConfiguration {
        LaunchConfiguration(restoreState: false)
    }
}

// MARK: - Launch Error

/// Errors that can occur during application launching
public enum LaunchError: Error, LocalizedError {
    case applicationNotFound(String)
    case bundleIdentifierNotFound(URL)
    case launchTimeout(TimeInterval)
    case checkInTimeout(TimeInterval)
    case launchFailed(underlying: Error)
    case asnCreationFailed(pid_t)
    case unknownError

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound(let identifier):
            return "Application not found: \(identifier)"
        case .bundleIdentifierNotFound(let url):
            return "Could not get bundle identifier for: \(url.path)"
        case .launchTimeout(let timeout):
            return "Timeout waiting for application to launch (\(timeout)s)"
        case .checkInTimeout(let timeout):
            return "Timeout waiting for application to finish launching (\(timeout)s)"
        case .launchFailed(let underlying):
            return "Launch failed: \(underlying.localizedDescription)"
        case .asnCreationFailed(let pid):
            return "Failed to create ASN for PID: \(pid)"
        case .unknownError:
            return "An unknown error occurred"
        }
    }
}

// MARK: - Launch Result

/// Result of a successful application launch
public struct LaunchResult: Sendable {
    /// The running application instance
    public let application: NSRunningApplication

    /// The time taken to launch
    public let launchDuration: TimeInterval

    /// Whether the application was already running
    public let wasAlreadyRunning: Bool

    /// Whether the application finished launching (for synchronous launches)
    public let isFinishedLaunching: Bool

    public init(
        application: NSRunningApplication,
        launchDuration: TimeInterval,
        wasAlreadyRunning: Bool,
        isFinishedLaunching: Bool
    ) {
        self.application = application
        self.launchDuration = launchDuration
        self.wasAlreadyRunning = wasAlreadyRunning
        self.isFinishedLaunching = isFinishedLaunching
    }
}
