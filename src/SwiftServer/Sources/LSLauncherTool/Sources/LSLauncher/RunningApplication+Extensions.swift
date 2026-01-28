import Foundation
import AppKit

// MARK: - NSRunningApplication Extensions

extension NSRunningApplication {

    /// The current application mode (foreground, UIElement, or background)
    public var applicationMode: ApplicationMode? {
        LSApplicationLauncher.shared.getApplicationMode(for: self)
    }

    /// Whether this application is currently visible in the Dock
    public var isVisibleInDock: Bool {
        applicationMode == .foreground
    }

    /// Whether this application is suppressed (hidden from Dock)
    public var isSuppressed: Bool {
        guard let mode = applicationMode else { return false }
        return mode != .foreground
    }

    /// Suppress this application (hide it from the Dock)
    /// - Throws: An error if the operation fails
    public func suppress() throws {
        try LSApplicationLauncher.shared.suppress(self)
    }

    /// Suppress this application to background mode (no dock, no UI)
    /// - Throws: An error if the operation fails
    public func suppressToBackground() throws {
        try LSApplicationLauncher.shared.suppressToBackground(self)
    }

    /// Promote this application back to foreground (show in Dock)
    /// - Throws: An error if the operation fails
    public func promote() throws {
        try LSApplicationLauncher.shared.promote(self)
    }

    /// Set the application mode
    /// - Parameter mode: The new application mode
    /// - Returns: The OS status (noErr on success)
    @discardableResult
    public func setApplicationMode(_ mode: ApplicationMode) -> OSStatus {
        LSApplicationLauncher.shared.setApplicationMode(for: self, to: mode)
    }

    /// Lock this application to UIElement mode, preventing self-promotion to foreground.
    /// Sets both the current type and restore type to UIElement.
    /// - Throws: An error if the operation fails
    public func lockToUIElement() throws {
        try LSApplicationLauncher.shared.lockToUIElement(self)
    }

    /// Check if this application is responsive by sending a ping AppleEvent.
    /// - Parameter timeout: Timeout in seconds (default 2 seconds)
    /// - Returns: true if the application responds within the timeout
    public func isResponsive(timeout: TimeInterval = 2.0) -> Bool {
        LSApplicationLauncher.shared.isResponsive(self, timeout: timeout)
    }

    /// Whether this application appears to be a zombie (running but unresponsive).
    /// Uses a 2-second timeout by default.
    public var isZombie: Bool {
        !isResponsive(timeout: 2.0)
    }
}

// MARK: - Array Extensions for Running Applications

extension Array where Element == NSRunningApplication {

    /// Suppress all applications in this array
    public func suppressAll() throws {
        for app in self {
            try app.suppress()
        }
    }

    /// Promote all applications in this array to foreground
    public func promoteAll() throws {
        for app in self {
            try app.promote()
        }
    }

    /// Filter to only foreground applications
    public var foregroundApps: [NSRunningApplication] {
        filter { $0.applicationMode == .foreground }
    }

    /// Filter to only UIElement applications
    public var uiElementApps: [NSRunningApplication] {
        filter { $0.applicationMode == .uiElement }
    }

    /// Filter to only background applications
    public var backgroundApps: [NSRunningApplication] {
        filter { $0.applicationMode == .backgroundOnly }
    }

    /// Filter to only suppressed applications (not foreground)
    public var suppressedApps: [NSRunningApplication] {
        filter { $0.isSuppressed }
    }
}

// MARK: - Convenience for Finding Applications

extension NSRunningApplication {

    /// Find all running instances of an application by bundle identifier
    /// - Parameter bundleIdentifier: The bundle identifier to search for
    /// - Returns: Array of running application instances
    public static func instances(withBundleIdentifier bundleIdentifier: String) -> [NSRunningApplication] {
        runningApplications(withBundleIdentifier: bundleIdentifier)
    }

    /// Check if any instance of an application with the given bundle identifier is running
    /// - Parameter bundleIdentifier: The bundle identifier to check
    /// - Returns: true if at least one instance is running
    public static func isRunning(bundleIdentifier: String) -> Bool {
        !runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Get the first running instance of an application by bundle identifier
    /// - Parameter bundleIdentifier: The bundle identifier to search for
    /// - Returns: The first running instance, or nil if not running
    public static func firstInstance(withBundleIdentifier bundleIdentifier: String) -> NSRunningApplication? {
        runningApplications(withBundleIdentifier: bundleIdentifier).first
    }
}
