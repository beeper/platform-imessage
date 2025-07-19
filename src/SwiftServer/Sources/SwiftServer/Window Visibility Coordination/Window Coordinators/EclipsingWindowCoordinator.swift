import Cocoa
import AccessibilityControl
import Logging

private let log = Logger(swiftServerLabel: "eclipsing-window-coordinator")

// NOTE: defaults for the defaults are registered in Defaults.swift

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

        var messagesFrame = try messagesWindow.frame()
        if windowFramePreEclipse == nil {
            windowFramePreEclipse = messagesFrame
        } else {
            // we already have a known frame, don't overwrite it with the eclisped frame
        }

        var targetSize = Self.eclipsingSize
        if targetSize.height == 0 {
            // If `height` is 0, then the default value was overridden with a different/invalid type.
            // Assume the user wants the height to match (so setting "match" as the height produces the desired effect).
            targetSize.height = largestElectronWindow.frame.height
        } else if targetSize.height < 0 {
            // If the `height` is a negative number, treat it as a delta that's applied to the Beeper window height.
            // Clamp to the minimum height because this "delta height" represents a best-effort preference.
            targetSize.height = max(Self.messagesAppMinimumSize.height, largestElectronWindow.frame.height + targetSize.height)
        }

        if !Self.messagesAppMinimumSize.encompasses(targetSize) {
            log.warning("target size \(targetSize) is smaller than the minimum size \(Self.messagesAppMinimumSize), trying anyways")
        }

        let electronFrame = largestElectronWindow.frame
        guard electronFrame.size.encompasses(targetSize) || !Self.shouldOnlyEclipseIfEncompasses else {
            log.warning("the largest Electron window's frame \(largestElectronWindow.frame) isn't big enough to encompass the target size \(targetSize), _not_ eclipsing")
            return
        }

        // NOTE: This points to the top left point of the window.
        var newPosition = {
            var base = electronFrame.origin

            if Self.eclipsingAlignment == "right" {
                // Make the right edge of the Messages window hug the right edge of the Beeper window.
                // This is useful to avoid the window showing through a material in the Beeper window.
                base.x = largestElectronWindow.frame.maxX - targetSize.width
            } else {
                // `electronOrigin` is "left-aligned" by default.
            }

            base.x += Self.eclipsingOffsetX
            base.y += Self.eclipsingOffsetY
            return base
        }()

        let targetRect = NSRect(origin: newPosition, size: targetSize)
        log.debug("electron frame: \(electronFrame.formatted)")
        if let screen = largestElectronWindow.screen {
            log.debug("screen with electron frame: \(screen.frame.formatted) [visible: \(screen.visibleFrame.formatted)]")
        }
        if let main = NSScreen.main {
            log.debug("main screen: \(main.frame.formatted) [visible: \(main.visibleFrame.formatted)]")
        }
        log.notice("eclipsing (\(messagesFrame.formatted) -> \(targetRect.formatted))")

        hideDebouncer.immediatelyUnhide()
        try messagesWindow.size(assign: targetSize)
        try messagesWindow.position(assign: newPosition)

        if #available(macOS 14, *) {
            let target = CGRect(origin: newPosition, size: targetSize)
            Task { @MainActor in
                guard Defaults.swiftServer.bool(forKey: DefaultsKeys.eclipsingDebug) else { return }
                let debugger = EclipsingDebugger.shared
                debugger.note(EclipsingRect(rect: messagesFrame, label: "Messages.app Pre-Eclipse Frame", color: NSColor.systemRed.cgColor))
                debugger.note(EclipsingRect(rect: electronFrame, label: "Electron", color: NSColor.systemGray.cgColor))
                debugger.note(EclipsingRect(rect: target, label: "Eclipsing Target", color: NSColor.systemGreen.cgColor))
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
