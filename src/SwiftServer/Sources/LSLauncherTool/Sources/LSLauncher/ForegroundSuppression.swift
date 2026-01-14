import Foundation
import AppKit

// MARK: - Foreground Suppression Options

/// Configuration for suppressing foreground activation when opening URLs
public struct ForegroundSuppressionOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Use _kLSOpenOptionActivateKey = false
    public static let noActivate = ForegroundSuppressionOptions(rawValue: 1 << 0)

    /// Use _kLSOpenOptionLaunchIsUserActionKey = false
    public static let notUserAction = ForegroundSuppressionOptions(rawValue: 1 << 1)

    /// Use _kLSOpenOptionUIElementLaunchKey = true
    public static let uiElementLaunch = ForegroundSuppressionOptions(rawValue: 1 << 2)

    /// Use _kLSOpenOptionForegroundLaunchKey = false
    public static let noForegroundLaunch = ForegroundSuppressionOptions(rawValue: 1 << 3)

    /// Use LSLaunchDoNotBringFrontmost = true in modifiers
    public static let doNotBringFrontmost = ForegroundSuppressionOptions(rawValue: 1 << 4)

    /// Use LSDoNotBringAnyWindowsForward = true in modifiers
    public static let noWindowBringForward = ForegroundSuppressionOptions(rawValue: 1 << 5)

    /// Set LSDisableAllPostLaunchBringForwardRequests on target app
    public static let disablePostLaunchBringForward = ForegroundSuppressionOptions(rawValue: 1 << 6)

    /// Lock target app to UIElement mode before opening URL
    public static let lockToUIElement = ForegroundSuppressionOptions(rawValue: 1 << 7)

    /// Set _kLSOpenOptionHideKey = true
    public static let hide = ForegroundSuppressionOptions(rawValue: 1 << 8)

    // MARK: - Preset Combinations

    /// Minimal suppression - just don't activate
    public static let minimal: ForegroundSuppressionOptions = [.noActivate]

    /// Standard suppression - activate=false + not user action
    public static let standard: ForegroundSuppressionOptions = [.noActivate, .notUserAction, .noForegroundLaunch]

    /// Strong suppression - adds launch modifiers
    public static let strong: ForegroundSuppressionOptions = [
        .noActivate, .notUserAction, .noForegroundLaunch,
        .doNotBringFrontmost, .noWindowBringForward
    ]

    /// Maximum suppression - everything including session-level flag
    public static let maximum: ForegroundSuppressionOptions = [
        .noActivate, .notUserAction, .noForegroundLaunch,
        .doNotBringFrontmost, .noWindowBringForward,
        .disablePostLaunchBringForward, .lockToUIElement
    ]

    /// All options enabled
    public static let all: ForegroundSuppressionOptions = [
        .noActivate, .notUserAction, .uiElementLaunch, .noForegroundLaunch,
        .doNotBringFrontmost, .noWindowBringForward,
        .disablePostLaunchBringForward, .lockToUIElement, .hide
    ]
}

// MARK: - Suppression Result

/// Result of a URL open operation with suppression
public struct SuppressionResult: Sendable {
    /// Whether the URL was dispatched successfully
    public let dispatched: Bool

    /// The options that were applied
    public let appliedOptions: ForegroundSuppressionOptions

    /// The target application's mode before the operation
    public let modeBeforeOpen: ApplicationMode?

    /// The target application's mode after the operation (after brief delay)
    public let modeAfterOpen: ApplicationMode?

    /// Whether the app was frontmost before the operation
    public let wasFrontmostBefore: Bool

    /// Whether the app became frontmost after the operation
    public let becameFrontmost: Bool

    /// Whether suppression was effective (app didn't come to front)
    public var suppressionEffective: Bool {
        !becameFrontmost
    }
}

// MARK: - ForegroundSuppressionTester

/// Test harness for experimenting with foreground suppression methods
public final class ForegroundSuppressionTester: @unchecked Sendable {

    public static let shared = ForegroundSuppressionTester()

    private let launcher = LSApplicationLauncher.shared

    private init() {}

    // MARK: - Open URL with Suppression

    /// Open a URL in a running application with foreground suppression
    /// - Parameters:
    ///   - url: The URL to open
    ///   - app: The target running application
    ///   - options: Suppression options to apply
    ///   - waitTime: Time to wait after dispatch to check results (default 0.5s)
    /// - Returns: Result describing what happened
    public func openURL(
        _ url: URL,
        in app: NSRunningApplication,
        options: ForegroundSuppressionOptions,
        waitTime: TimeInterval = 0.5
    ) throws -> SuppressionResult {
        guard let asn = launcher.getASN(for: app) else {
            throw LaunchError.asnCreationFailed(app.processIdentifier)
        }

        // Capture state before
        let modeBefore = app.applicationMode
        let frontAppBefore = NSWorkspace.shared.frontmostApplication
        let wasFrontmostBefore = frontAppBefore?.processIdentifier == app.processIdentifier

        // Apply pre-open modifications
        if options.contains(.lockToUIElement) {
            try launcher.lockToUIElement(app)
        }

        if options.contains(.disablePostLaunchBringForward) {
            setDisableAllPostLaunchBringForward(for: app, enabled: true)
        }

        // Build options dictionary
        var optionsDict: [String: Any] = [:]

        if options.contains(.noActivate) {
            optionsDict[LSFrontBoardOptionKey.activate] = false
        }

        if options.contains(.notUserAction) {
            optionsDict[LSFrontBoardOptionKey.launchIsUserAction] = false
        }

        if options.contains(.uiElementLaunch) {
            optionsDict[LSFrontBoardOptionKey.uiElementLaunch] = true
        }

        if options.contains(.noForegroundLaunch) {
            optionsDict[LSFrontBoardOptionKey.foregroundLaunch] = false
        }

        if options.contains(.hide) {
            optionsDict[LSFrontBoardOptionKey.hide] = true
        }

        if options.contains(.doNotBringFrontmost) {
            optionsDict[LSLaunchModifierKey.doNotBringFrontmost] = true
        }

        if options.contains(.noWindowBringForward) {
            optionsDict[LSLaunchModifierKey.doNotBringAnyWindowsForward] = true
        }

        // Dispatch the URL
        launcher.openURLs([url], targetASN: asn, activate: false, preferRunningInstance: true)

        // Wait for the operation to complete
        Thread.sleep(forTimeInterval: waitTime)

        // Capture state after
        let modeAfter = app.applicationMode
        let frontAppAfter = NSWorkspace.shared.frontmostApplication
        let becameFrontmost = frontAppAfter?.processIdentifier == app.processIdentifier && !wasFrontmostBefore

        return SuppressionResult(
            dispatched: true,
            appliedOptions: options,
            modeBeforeOpen: modeBefore,
            modeAfterOpen: modeAfter,
            wasFrontmostBefore: wasFrontmostBefore,
            becameFrontmost: becameFrontmost
        )
    }

    // MARK: - Session-Level Suppression

    /// Set the LSDisableAllPostLaunchBringForwardRequests flag for an app
    /// - Parameters:
    ///   - app: The target application
    ///   - enabled: Whether to enable or disable the flag
    @discardableResult
    public func setDisableAllPostLaunchBringForward(for app: NSRunningApplication, enabled: Bool) -> OSStatus {
        guard let asn = launcher.getASN(for: app) else {
            return OSStatus(kLSApplicationNotFoundErr)
        }
        return launcher.setApplicationInfo(
            asn: asn,
            key: LSMetaInfoKey.disableAllPostLaunchBringForwardRequests as CFString,
            value: enabled ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    /// Get the current LSDisableAllPostLaunchBringForwardRequests flag for an app
    public func getDisableAllPostLaunchBringForward(for app: NSRunningApplication) -> Bool? {
        guard let asn = launcher.getASN(for: app) else { return nil }
        let value = launcher.getApplicationInfo(
            asn: asn,
            key: LSMetaInfoKey.disableAllPostLaunchBringForwardRequests as CFString
        )
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let cfBool = value, CFGetTypeID(cfBool) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(cfBool as! CFBoolean)
        }
        return nil
    }

    // MARK: - Test Methods

    /// Run a comprehensive test of all suppression methods
    /// - Parameters:
    ///   - url: URL to open
    ///   - app: Target application
    /// - Returns: Array of results for each method tested
    public func runComprehensiveTest(
        url: URL,
        app: NSRunningApplication
    ) throws -> [(name: String, options: ForegroundSuppressionOptions, result: SuppressionResult)] {
        var results: [(String, ForegroundSuppressionOptions, SuppressionResult)] = []

        let testCases: [(String, ForegroundSuppressionOptions)] = [
            ("No suppression (baseline)", []),
            ("Minimal (noActivate only)", .minimal),
            ("Standard (activate + notUserAction)", .standard),
            ("Strong (+ launch modifiers)", .strong),
            ("Lock to UIElement only", [.lockToUIElement]),
            ("Session flag only", [.disablePostLaunchBringForward]),
            ("Maximum suppression", .maximum),
        ]

        for (name, options) in testCases {
            // Reset app state between tests
            if app.applicationMode != .uiElement {
                try? launcher.lockToUIElement(app)
            }
            Thread.sleep(forTimeInterval: 0.2)

            let result = try openURL(url, in: app, options: options)
            results.append((name, options, result))

            // Brief pause between tests
            Thread.sleep(forTimeInterval: 0.3)
        }

        return results
    }

    /// Test a single specific suppression configuration
    public func testSingleConfiguration(
        url: URL,
        app: NSRunningApplication,
        options: ForegroundSuppressionOptions,
        iterations: Int = 3
    ) throws -> [SuppressionResult] {
        var results: [SuppressionResult] = []

        for _ in 0..<iterations {
            let result = try openURL(url, in: app, options: options)
            results.append(result)
            Thread.sleep(forTimeInterval: 0.5)
        }

        return results
    }
}

// MARK: - Custom Options Builder

/// Builder for constructing custom suppression configurations
public class SuppressionOptionsBuilder {
    private var options: ForegroundSuppressionOptions = []

    public init() {}

    @discardableResult
    public func noActivate() -> Self {
        options.insert(.noActivate)
        return self
    }

    @discardableResult
    public func notUserAction() -> Self {
        options.insert(.notUserAction)
        return self
    }

    @discardableResult
    public func uiElementLaunch() -> Self {
        options.insert(.uiElementLaunch)
        return self
    }

    @discardableResult
    public func noForegroundLaunch() -> Self {
        options.insert(.noForegroundLaunch)
        return self
    }

    @discardableResult
    public func doNotBringFrontmost() -> Self {
        options.insert(.doNotBringFrontmost)
        return self
    }

    @discardableResult
    public func noWindowBringForward() -> Self {
        options.insert(.noWindowBringForward)
        return self
    }

    @discardableResult
    public func disablePostLaunchBringForward() -> Self {
        options.insert(.disablePostLaunchBringForward)
        return self
    }

    @discardableResult
    public func lockToUIElement() -> Self {
        options.insert(.lockToUIElement)
        return self
    }

    @discardableResult
    public func hide() -> Self {
        options.insert(.hide)
        return self
    }

    public func build() -> ForegroundSuppressionOptions {
        return options
    }
}

// MARK: - Convenience Extension

extension ForegroundSuppressionOptions: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if contains(.noActivate) { parts.append("noActivate") }
        if contains(.notUserAction) { parts.append("notUserAction") }
        if contains(.uiElementLaunch) { parts.append("uiElementLaunch") }
        if contains(.noForegroundLaunch) { parts.append("noForegroundLaunch") }
        if contains(.doNotBringFrontmost) { parts.append("doNotBringFrontmost") }
        if contains(.noWindowBringForward) { parts.append("noWindowBringForward") }
        if contains(.disablePostLaunchBringForward) { parts.append("disablePostLaunchBringForward") }
        if contains(.lockToUIElement) { parts.append("lockToUIElement") }
        if contains(.hide) { parts.append("hide") }
        return parts.isEmpty ? "(none)" : parts.joined(separator: ", ")
    }
}
