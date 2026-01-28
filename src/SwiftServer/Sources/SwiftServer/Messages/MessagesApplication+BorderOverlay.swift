import AppKit
import AccessibilityControl
import Combine
import Foundation
import SwiftServerFoundation

// MARK: - BorderView

/// Custom view that draws a colored border with a label
class BorderView: NSView {
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

// MARK: - MessagesApplication Border Overlay Extension

@available(macOS 11, *)
extension MessagesApplication {
    @MainActor
    func startBorderOverlays() {
        Self.logger.info("Starting border overlays")

        // Create border window for public instance
        if let publicApp = publicInstance?.runningApplication {
            publicBorderWindow = createBorderWindow(color: .systemGreen, label: "Public")
            if let mainWindow = try? publicApp.elements.mainWindow {
                updateBorderWindow(publicBorderWindow, forWindowElement: mainWindow)
            }
            subscribeToWindowEvents(for: publicApp, borderWindow: publicBorderWindow)
        }

        // Create border window for puppet instance
        if let puppetApp = puppetInstance?.runningApplication {
            puppetBorderWindow = createBorderWindow(color: .systemBlue, label: "Puppet")
            if let mainWindow = try? puppetApp.elements.mainWindow {
                updateBorderWindow(puppetBorderWindow, forWindowElement: mainWindow)
            }
            subscribeToWindowEvents(for: puppetApp, borderWindow: puppetBorderWindow)
        }
    }

    @MainActor
    func stopBorderOverlays() {
        // First, hide the windows to stop any visual updates
        publicBorderWindow?.orderOut(nil)
        puppetBorderWindow?.orderOut(nil)

        // Clear the cancellables to stop event subscriptions
        // This must happen before closing windows to prevent callbacks during teardown
        windowEventCancellables.removeAll()

        // Close and release the windows
        // Note: We set isReleasedWhenClosed = false in createBorderWindow,
        // so we can safely nil these out without double-release
        publicBorderWindow?.close()
        publicBorderWindow = nil
        puppetBorderWindow?.close()
        puppetBorderWindow = nil

        Self.logger.info("Stopped border overlays")
    }

    @MainActor
    func observeBorderOverlaySetting() {
        // Track current state to detect changes
        var currentValue = Defaults.swiftServer.bool(forKey: DefaultsKeys.showInstanceBorders)

        // Check initial value
        if currentValue {
            startBorderOverlays()
        }

        // Observe changes via NotificationCenter
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: Defaults.swiftServer)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let newValue = Defaults.swiftServer.bool(forKey: DefaultsKeys.showInstanceBorders)
                guard newValue != currentValue else { return }
                currentValue = newValue

                if newValue {
                    self.startBorderOverlays()
                } else {
                    self.stopBorderOverlays()
                }
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func createBorderWindow(color: NSColor, label: String) -> NSWindow {
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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false  // Prevent double-release when we nil the reference

        let borderView = BorderView(color: color, borderWidth: 3, label: label)
        window.contentView = borderView

        return window
    }

    /// Converts a frame from AX coordinates (origin at top-left) to Cocoa coordinates (origin at bottom-left)
    private func convertAXFrameToCocoaFrame(_ axFrame: NSRect) -> NSRect {
        // AX uses top-left origin, Cocoa uses bottom-left origin
        // We need to flip the y coordinate
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: axFrame.midX, y: axFrame.midY)) }) ?? NSScreen.main else {
            return axFrame
        }

        let screenHeight = screen.frame.height
        let cocoaY = screenHeight - axFrame.origin.y - axFrame.height

        return NSRect(
            x: axFrame.origin.x,
            y: cocoaY,
            width: axFrame.width,
            height: axFrame.height
        )
    }

    @MainActor
    private func updateBorderWindow(_ borderWindow: NSWindow?, forWindowElement windowElement: Accessibility.Element) {
        guard let borderWindow else { return }

        do {
            let axFrame = try windowElement.frame()
            let cocoaFrame = convertAXFrameToCocoaFrame(axFrame)
            borderWindow.setFrame(cocoaFrame, display: true)
            borderWindow.orderFront(nil)
        } catch {
            Self.logger.debug("Failed to update border window: \(error)")
            borderWindow.orderOut(nil)
        }
    }

    private func subscribeToWindowEvents(for app: NSRunningApplication, borderWindow: NSWindow?) {
        guard let publisher = app.windowEventPublisher() else {
            Self.logger.warning("Failed to create window event publisher for pid=\(app.processIdentifier)")
            return
        }

        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak borderWindow] event in
                guard let self, let borderWindow else { return }

                Task { @MainActor in
                    self.updateBorderWindow(borderWindow, forWindowElement: event.window)
                }
            }
            .store(in: &windowEventCancellables)
    }
}
