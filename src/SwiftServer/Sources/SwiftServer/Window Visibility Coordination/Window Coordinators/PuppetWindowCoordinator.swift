import Cocoa
import AccessibilityControl
import Logging

private let log = Logger(swiftServerLabel: "puppet-window-coordinator")

/// A window coordinator designed specifically for the puppet instance strategy.
///
/// Unlike `EclipsingWindowCoordinator`, this coordinator:
/// - Does not aggressively hide the Messages window (the puppet instance is already suppressed)
/// - Does not restore the window frame on user interaction (the puppet is not meant for user interaction)
/// - Positions the window completely behind the Beeper window with no visible edges
@available(macOS 11, *)
final class PuppetWindowCoordinator: WindowCoordinator {
    var app: NSRunningApplication? {
        didSet {
            if let app {
                log.info("now coordinating puppet instance \(app.processIdentifier)")
                // Don't hide immediately - the puppet instance is already suppressed
            } else {
                log.info("no longer coordinating puppet instance")
            }
        }
    }

    var canReuseExtantInstance: Bool { false }

    private var hasPositionedWindow = false

    init() {}

    func makeAutomatable(_ messagesWindow: Accessibility.Element) throws {
        guard let largestElectronWindow = NSApp.largestElectronWindow else {
            log.warning("couldn't find Electron window, positioning at default location")
            try positionAtDefaultLocation(messagesWindow)
            return
        }

        let electronFrame = largestElectronWindow.frame
        guard let screen = largestElectronWindow.screen else {
            log.warning("can't determine screen for Electron window, using main screen")
            try positionBehindFrame(messagesWindow, frame: electronFrame, screen: NSScreen.main)
            return
        }

        try positionBehindFrame(messagesWindow, frame: electronFrame, screen: screen)
    }

    private func positionBehindFrame(_ messagesWindow: Accessibility.Element, frame electronFrame: NSRect, screen: NSScreen?) throws {
        // Convert from Cocoa coordinates (origin at bottom-left) to screen coordinates (origin at top-left)
        let screenHeight = screen?.frame.height ?? NSScreen.main?.frame.height ?? 1000
        let flippedY = screenHeight - electronFrame.maxY

        // Calculate target size - match the Electron window or use minimum size
        let targetSize = NSSize(
            width: max(Self.messagesAppMinimumSize.width, electronFrame.width),
            height: max(Self.messagesAppMinimumSize.height, electronFrame.height)
        )

        // Position the Messages window to be completely behind the Beeper window
        // Add insets so no edges (including shadows) are visible
        let inset: CGFloat = 20 // Account for window shadows
        let targetOrigin = NSPoint(
            x: electronFrame.origin.x + inset,
            y: flippedY + inset
        )

        // Adjust size to account for insets (make it smaller so it fits entirely behind)
        let adjustedSize = NSSize(
            width: targetSize.width - (inset * 2),
            height: targetSize.height - (inset * 2)
        )

        // Ensure we meet minimum size requirements
        let finalSize = NSSize(
            width: max(Self.messagesAppMinimumSize.width, adjustedSize.width),
            height: max(Self.messagesAppMinimumSize.height, adjustedSize.height)
        )

        let targetRect = NSRect(origin: targetOrigin, size: finalSize)
        log.debug("positioning puppet window behind Electron: \(targetRect.formatted)")

        try messagesWindow.size(assign: finalSize)
        try messagesWindow.position(assign: targetOrigin)

        hasPositionedWindow = true
    }

    private func positionAtDefaultLocation(_ messagesWindow: Accessibility.Element) throws {
        // Fallback: position off-screen to the left
        let screenHeight = NSScreen.main?.frame.height ?? 1000
        let targetOrigin = NSPoint(x: -Self.messagesAppMinimumSize.width - 100, y: screenHeight / 2)

        try messagesWindow.size(assign: Self.messagesAppMinimumSize)
        try messagesWindow.position(assign: targetOrigin)

        hasPositionedWindow = true
    }

    func automationDidComplete(_ window: Accessibility.Element) throws {
        // Don't hide - the puppet instance stays in place behind the Beeper window
        // It's already suppressed so it won't appear in the dock or app switcher
    }

    func reset(_ window: Accessibility.Element) throws {
        // No-op for puppet instance - we don't restore frames since users shouldn't interact with it
    }

    func userManuallyActivated(_ app: NSRunningApplication) throws {
        // No-op - if the puppet somehow gets activated, we don't need to do anything special
        // The auto-suppression in MessagesApplication will handle it
    }

    func userManuallyDeactivated(_ app: NSRunningApplication) throws {
        // No-op
    }

    // MARK: - Constants

    static let messagesAppMinimumSize = NSSize(width: 660.0, height: 320.0)
}

// MARK: - Extensions

private extension NSRect {
    var formatted: String {
        "@\(origin.x),\(origin.y)[\(size.width)x\(size.height)]"
    }
}
