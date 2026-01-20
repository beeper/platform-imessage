import AccessibilityControl
import AppKit
import Combine
import SwiftServerFoundation

/// Displays colored border overlays around Messages windows to help identify
/// which instance is the public instance vs the puppet instance.
/// - Green border: Public instance (user-facing)
/// - Blue border: Puppet instance (automation)
@available(macOS 11, *)
public final class InstanceBorderOverlay {
    private var overlayWindows: [pid_t: NSWindow] = [:]
    private weak var messagesApplication: MessagesApplication?

    /// Observer tokens for window events, keyed by pid
    private var windowMovedTokens: [pid_t: Accessibility.Observer.Token] = [:]
    private var windowResizedTokens: [pid_t: Accessibility.Observer.Token] = [:]
    private var windowCreatedTokens: [pid_t: Accessibility.Observer.Token] = [:]

    /// Track which PIDs we're currently observing
    private var observedPids: Set<pid_t> = []

    private var isRunning = false

    private static let borderWidth: CGFloat = 4
    private static let borderAlpha: CGFloat = 0.85
    private static let publicColor = NSColor.systemGreen.withAlphaComponent(borderAlpha)
    private static let puppetColor = NSColor.systemBlue.withAlphaComponent(borderAlpha)

    public init(messagesApplication: MessagesApplication) {
        self.messagesApplication = messagesApplication
    }

    deinit {
        stop()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Update immediately and set up observers
        updateOverlays()
    }

    public func stop() {
        isRunning = false

        // Cancel all observer tokens
        windowMovedTokens.removeAll()
        windowResizedTokens.removeAll()
        windowCreatedTokens.removeAll()
        observedPids.removeAll()

        // Remove all overlay windows
        for window in overlayWindows.values {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    private func updateOverlays() {
        guard let app = messagesApplication, isRunning else { return }

        // Check if borders should be shown
        let shouldShow = Defaults.swiftServer.bool(forKey: DefaultsKeys.showInstanceBorders)
        guard shouldShow else {
            // Hide all overlays when disabled
            for window in overlayWindows.values {
                window.orderOut(nil)
            }
            return
        }

        // Get current instances
        let publicPid = app.publicInstance?.pid
        let puppetPid = app.puppetInstance?.pid

        // Track which PIDs are still active
        var activePids: Set<pid_t> = []

        // Update or create overlay for public instance
        if let pid = publicPid, let runningApp = app.publicInstance?.runningApplication {
            activePids.insert(pid)
            updateOverlay(for: pid, runningApplication: runningApp, color: Self.publicColor, label: "PUBLIC")
            setupObservers(for: pid)
        }

        // Update or create overlay for puppet instance
        if let pid = puppetPid, let runningApp = app.puppetInstance?.runningApplication {
            activePids.insert(pid)
            updateOverlay(for: pid, runningApplication: runningApp, color: Self.puppetColor, label: "PUPPET")
            setupObservers(for: pid)
        }

        // Remove overlays and observers for instances that no longer exist
        let staleKeys = overlayWindows.keys.filter { !activePids.contains($0) }
        for key in staleKeys {
            overlayWindows[key]?.orderOut(nil)
            overlayWindows.removeValue(forKey: key)
            removeObservers(for: key)
        }
    }

    private func setupObservers(for pid: pid_t) {
        guard !observedPids.contains(pid) else { return }
        observedPids.insert(pid)

        let appElement = Accessibility.Element(pid: pid)

        do {
            // Observe window creation on the app element
            windowCreatedTokens[pid] = try appElement.observe(.windowCreated) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateOverlays()
                }
            }

            // Try to get the main window and observe it
            let windowsAttr: Accessibility.Attribute<[Accessibility.Element]> = appElement.attribute(.init("AXWindows"))
            if let windowElement = try? windowsAttr[0] {
                windowMovedTokens[pid] = try windowElement.observe(.windowMoved) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.updateOverlays()
                    }
                }

                windowResizedTokens[pid] = try windowElement.observe(.windowResized) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.updateOverlays()
                    }
                }
            }
        } catch {
            // If observation fails, we'll just rely on window creation events
            // or the initial update
        }
    }

    private func removeObservers(for pid: pid_t) {
        observedPids.remove(pid)
        windowMovedTokens.removeValue(forKey: pid)
        windowResizedTokens.removeValue(forKey: pid)
        windowCreatedTokens.removeValue(forKey: pid)
    }

    private func updateOverlay(for pid: pid_t, runningApplication: NSRunningApplication, color: NSColor, label: String) {
        // Get the window frame using accessibility
        guard let frame = getMainWindowFrame(for: runningApplication) else {
            // Window not visible, hide overlay
            overlayWindows[pid]?.orderOut(nil)
            return
        }

        // Get or create overlay window
        let overlayWindow: NSWindow
        if let existing = overlayWindows[pid] {
            overlayWindow = existing
        } else {
            overlayWindow = createOverlayWindow(color: color, label: label)
            overlayWindows[pid] = overlayWindow
        }

        // Position overlay to match the target window
        // Add padding for the border
        let borderWidth = Self.borderWidth
        let overlayFrame = NSRect(
            x: frame.origin.x - borderWidth,
            y: frame.origin.y - borderWidth,
            width: frame.width + borderWidth * 2,
            height: frame.height + borderWidth * 2
        )

        overlayWindow.setFrame(overlayFrame, display: true)
        overlayWindow.orderFront(nil)
    }

    private func createOverlayWindow(color: NSColor, label: String) -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let contentView = BorderView(color: color, borderWidth: Self.borderWidth, label: label)
        window.contentView = contentView

        return window
    }

    private func getMainWindowFrame(for runningApplication: NSRunningApplication) -> NSRect? {
        // Use accessibility to get the window frame
        let element = AXUIElementCreateApplication(runningApplication.processIdentifier)

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement], let firstWindow = windows.first else {
            return nil
        }

        // Get position
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(firstWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              let positionRef = positionValue else {
            return nil
        }

        var position = CGPoint.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)

        // Get size
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(firstWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let sizeRef = sizeValue else {
            return nil
        }

        var size = CGSize.zero
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        // Convert from screen coordinates (top-left origin) to Cocoa coordinates (bottom-left origin)
        // Find the screen that contains this window
        let windowTopLeft = position

        // Find which screen contains the window (check screen frames in global coordinates)
        // NSScreen.screens is ordered with main screen first, then others
        var containingScreen: NSScreen?
        for screen in NSScreen.screens {
            // Convert screen frame to global coordinates (top-left origin)
            // screen.frame is in Cocoa coordinates (bottom-left origin relative to main screen)
            // We need to find the screen that contains the window's top-left corner in global coords
            let screenFrame = screen.frame
            let mainScreenHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height

            // Screen's top-left in global coordinates
            let screenMinY = mainScreenHeight - screenFrame.maxY
            let screenMaxY = mainScreenHeight - screenFrame.minY

            // Check if window's top-left is within this screen's bounds (in global coords)
            if windowTopLeft.x >= screenFrame.minX &&
               windowTopLeft.x < screenFrame.maxX &&
               windowTopLeft.y >= screenMinY &&
               windowTopLeft.y < screenMaxY {
                containingScreen = screen
                break
            }
        }

        // Fall back to main screen if we can't find containing screen
        guard let screen = containingScreen ?? NSScreen.main else { return nil }
        let mainScreen = NSScreen.screens.first ?? screen
        let mainScreenHeight = mainScreen.frame.height

        // Convert from global (top-left origin) to Cocoa (bottom-left origin)
        // In Cocoa coordinates, y=0 is at the bottom of the main screen
        let cocoaY = mainScreenHeight - position.y - size.height

        return NSRect(x: position.x, y: cocoaY, width: size.width, height: size.height)
    }
}

/// Custom view that draws a colored border with a label
private class BorderView: NSView {
    let color: NSColor
    let borderWidth: CGFloat
    let label: String

    init(color: NSColor, borderWidth: CGFloat, label: String) {
        self.color = color
        self.borderWidth = borderWidth
        self.label = label
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw the border
        let borderPath = NSBezierPath()
        borderPath.lineWidth = borderWidth

        // Outer rect
        let outerRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        borderPath.appendRect(outerRect)

        color.setStroke()
        borderPath.stroke()

        // Draw label background
        let labelFont = NSFont.boldSystemFont(ofSize: 11)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white
        ]
        let labelSize = label.size(withAttributes: labelAttributes)
        let labelPadding: CGFloat = 4
        let labelBackgroundRect = NSRect(
            x: bounds.midX - (labelSize.width + labelPadding * 2) / 2,
            y: bounds.maxY - borderWidth - labelSize.height - labelPadding,
            width: labelSize.width + labelPadding * 2,
            height: labelSize.height + labelPadding
        )

        color.setFill()
        NSBezierPath(roundedRect: labelBackgroundRect, xRadius: 3, yRadius: 3).fill()

        // Draw label text
        let labelRect = NSRect(
            x: labelBackgroundRect.origin.x + labelPadding,
            y: labelBackgroundRect.origin.y + labelPadding / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        label.draw(in: labelRect, withAttributes: labelAttributes)
    }
}
