import Cocoa
import AccessibilityControl
import Logging

private let log = Logger(swiftServerLabel: "eclipsing-window-coordinator")

// NOTE: default values for the defaults are registered in Defaults.swift

/**
 * Enables automation of the Messages app by briefly showing it behind the Beeper window whenever automation is needed.
 * (Otherwise, automation isn't possible.) Whenever automation is not needed, the app is hidden.
 *
 * Despite the app being repeatedly hidden and unhidden, it seems to reliably appear behind the Beeper window,
 * even if the user briefly takes manual control of Messages.
 */
final class EclipsingWindowCoordinator: WindowCoordinator {
    var app: NSRunningApplication? {
        didSet {
            if let app {
                log.info("now coordinating \(app.processIdentifier), hiding it immediately")
                app.hide()
            } else {
                log.info("no longer coordinating")
            }

            hideDebouncer.app = app
        }
    }

    private var windowFramePreEclipse: NSRect?
    private var hideDebouncer: HideDebouncer

    var canReuseExtantInstance: Bool { true }

    init() {
        hideDebouncer = HideDebouncer(debouncingFor: Self.debouncingPeriod)
    }

    func makeAutomatable(_ messagesWindow: Accessibility.Element) throws {
        let largestElectronWindow = try NSApp.largestElectronWindow.orThrow(WindowCoordinatorError.generic(message: "Couldn't find Electron window"))

        let originalMessagesFrame = try messagesWindow.frame()
        if windowFramePreEclipse == nil {
            windowFramePreEclipse = originalMessagesFrame
        } else {
            // we already have a known frame, don't overwrite it with the eclisped frame
        }

        var targetSize = Self.eclipsingSize
        if targetSize.height == 0 {
            // if `height` is 0, then the default value was overridden with a different/invalid type.
            // assume the user wants the height to match (so setting "match" as the height produces the desired effect).
            targetSize.height = largestElectronWindow.frame.height
        } else if targetSize.height < 0 {
            // if the `height` is a negative number, treat it as a delta that's applied to the Beeper window height.
            // clamp to the minimum height because this "delta height" represents a best-effort preference.
            targetSize.height = max(Self.messagesAppMinimumSize.height, largestElectronWindow.frame.height + targetSize.height)
        }

        if !Self.messagesAppMinimumSize.encompasses(targetSize) {
            log.warning("target size \(targetSize) is smaller than the minimum size \(Self.messagesAppMinimumSize), trying anyways")
        }

        let originalElectronFrame = largestElectronWindow.frame
        let flippedElectronFrame: NSRect = {
            guard let screen = largestElectronWindow.screen else {
                log.warning("can't determine which screen the electron window is on, using original frame which will result in an unexpected position")
                return originalElectronFrame
            }

            // the origin of the window frame is coincident with the bottom-left corner, and is in the cocoa coordinate space (origin at bottom-left)
            // however, the screen coordinate space (which is used when manipulating windows via AX) has the origin at the top-left
            // correct the frame to account for this
            return NSRect(
                origin: NSPoint(x: originalElectronFrame.origin.x, y: screen.frame.height - originalElectronFrame.maxY),
                size: originalElectronFrame.size,
            )
        }()
        log.debug("largest electron window frame (original): \(originalElectronFrame.formatted)")
        log.debug("largest electron window frame (in screen space): \(flippedElectronFrame.formatted)")
        if let screen = largestElectronWindow.screen {
            log.debug("screen with electron frame: \(screen.frame.formatted) [visible: \(screen.visibleFrame.formatted)]")
        }
        if let main = NSScreen.main {
            log.debug("main screen: \(main.frame.formatted) [visible: \(main.visibleFrame.formatted)]")
        }
        guard flippedElectronFrame.size.encompasses(targetSize) || !Self.shouldOnlyEclipseIfEncompasses else {
            log.warning("the largest Electron window's frame \(originalElectronFrame.formatted) isn't big enough to encompass the target size \(targetSize), _not_ eclipsing!")
            return
        }

        // NOTE: this refers to the top-left corner of the Messages window
        let targetOrigin = {
            var base = flippedElectronFrame.origin

            if Self.eclipsingAlignment == "right" {
                // make the right edge of the Messages window hug the right edge of the Beeper window.
                // this is useful to avoid the window showing through a material in the Beeper window.
                base.x = flippedElectronFrame.maxX - targetSize.width
            } else {
                // left-alignment is naturally default
            }

            // incorporate adjustments that may be used to e.g. avoid window shadows
            // from protruding
            base.x += Self.eclipsingOffsetX
            base.y += Self.eclipsingOffsetY
            return base
        }()

        let targetRect = NSRect(origin: targetOrigin, size: targetSize)
        log.notice("eclipsing (\(originalMessagesFrame.formatted) -> \(targetRect.formatted))")

        hideDebouncer.immediatelyUnhide()
        try messagesWindow.size(assign: targetSize)
        try messagesWindow.position(assign: targetOrigin)

        if #available(macOS 14, *), Defaults.swiftServer.bool(forKey: DefaultsKeys.eclipsingDebug) {
            Task { @MainActor in
                let debugger = EclipsingDebugger.shared
                debugger.note(EclipsingRect(at: originalMessagesFrame, label: "Original", color: NSColor.systemRed.cgColor))
                debugger.note(EclipsingRect(at: flippedElectronFrame, label: "Electron", color: NSColor.systemGray.cgColor))
                debugger.note(EclipsingRect(at: targetRect, label: "Target", color: NSColor.systemGreen.cgColor))
                // i think this is up-to-date by now? might need to wait for a next
                // runloop turn?
                guard let frame = try? messagesWindow.frame() else { return }
                EclipsingDebugger.shared.note(EclipsingRect(at: frame, label: "Final", color: NSColor.systemBlue.cgColor))
            }
        }
    }

    func automationDidComplete(_ window: Accessibility.Element) throws {
        hideDebouncer.requestHide()
    }

    func reset(_ window: Accessibility.Element) throws {
        hideDebouncer.immediatelyUnhide()

        guard let originalFrame = windowFramePreEclipse else {
            log.warning("no last known frame, not setting a frame back")
            return
        }

        defer {
            // preserve the next frame that we witness, in case the user adjusts it
            windowFramePreEclipse = nil
        }

        log.debug("resetting to original frame: \(originalFrame)")
        try window.setFrame(originalFrame)
    }

    func userManuallyActivated(_ app: NSRunningApplication) throws {
        hideDebouncer.immediatelyUnhide()
    }

    func userManuallyDeactivated(_ app: NSRunningApplication) throws {
        hideDebouncer.requestHide()
    }
}

private extension EclipsingWindowCoordinator {
    private static var debouncingPeriod: RunLoop.SchedulerTimeType.Stride { .init(Defaults.swiftServer.double(forKey: DefaultsKeys.hidingCoordinatorDebounce)) }
    private static var shouldOnlyEclipseIfEncompasses: Bool { Defaults.swiftServer.bool(forKey: DefaultsKeys.onlyEclipseIfEncompasses) }
    private static var eclipsingOffsetX: CGFloat { Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingOffsetX) }
    private static var eclipsingOffsetY: CGFloat { Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingOffsetY) }
    private static var eclipsingAlignment: String? { Defaults.swiftServer.string(forKey: DefaultsKeys.eclipsingAlignment) }

    private static var eclipsingSize: NSSize {
        NSSize(
            width: Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingWidth),
            height: Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingHeight)
        )
    }

    // Accurate as of macOS 15.3.2.
    static let messagesAppMinimumSize: NSSize = NSSize(width: 660.0, height: 320.0)
}

// MARK: - Extensions

private extension NSRect {
    var area: Double { size.area }

    func encompasses(_ other: CGRect) -> Bool {
        size.encompasses(other.size)
    }

    var formatted: String {
        "@\(origin.x),\(origin.y)[\(size.width)x\(size.height)]"
    }
}

private extension NSSize {
    var area: Double { width * height }

    func encompasses(_ other: NSSize) -> Bool {
        width >= other.width && height >= other.height
    }
}

extension NSApplication {
    var largestElectronWindow: NSWindow? {
        let prefix = Defaults.swiftServer.string(forKey: DefaultsKeys.eclipsingWindowClassNamePrefix) ?? "Electron"
        // XXX: It's likely possible for this read to race with Electron's main thread, or whatever actually owns the window.
        let electronWindows = windows.filter { NSStringFromClass(type(of: $0)).starts(with: prefix) }
        log.debug("found \(electronWindows.count) electron window(s)")

        if Defaults.swiftServer.bool(forKey: DefaultsKeys.eclipsingUsesLargestWindow) {
            let largest = electronWindows.max(by: { $0.frame.area < $1.frame.area })
            if let largest {
                log.debug("biggest has frame of \(largest.frame) (area: \(largest.frame.area))")
            }
            return largest
        } else {
            return electronWindows.first
        }
    }
}
