import Cocoa
import AccessibilityControl
import Logging
import WindowControl

private let log = Logger(imessageLabel: "eclipsing-window-coordinator")

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
        let anchorWindow = try Self.eclipsingAnchorWindow(messagesPID: app?.processIdentifier)

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
            targetSize.height = anchorWindow.screenFrame.height
        } else if targetSize.height < 0 {
            // if the `height` is a negative number, treat it as a delta that's applied to the Beeper window height.
            // clamp to the minimum height because this "delta height" represents a best-effort preference.
            targetSize.height = max(Self.messagesAppMinimumSize.height, anchorWindow.screenFrame.height + targetSize.height)
        }

        if !Self.messagesAppMinimumSize.encompasses(targetSize) {
            log.warning("target size \(targetSize) is smaller than the minimum size \(Self.messagesAppMinimumSize), trying anyways")
        }

        log.debug("eclipsing anchor: \(anchorWindow.description), frame: \(anchorWindow.screenFrame.formatted)")
        if let originalFrame = anchorWindow.originalFrame {
            log.debug("eclipsing anchor original frame: \(originalFrame.formatted)")
        }
        if let screen = anchorWindow.screen {
            log.debug("screen with anchor frame: \(screen.frame.formatted) [visible: \(screen.visibleFrame.formatted)]")
        }
        if let main = NSScreen.main {
            log.debug("main screen: \(main.frame.formatted) [visible: \(main.visibleFrame.formatted)]")
        }
        guard anchorWindow.screenFrame.size.encompasses(targetSize) || !Self.shouldOnlyEclipseIfEncompasses else {
            log.warning("the eclipsing anchor's frame \(anchorWindow.screenFrame.formatted) isn't big enough to encompass the target size \(targetSize), _not_ eclipsing!")
            return
        }

        // NOTE: this refers to the top-left corner of the Messages window
        let targetOrigin = {
            var base = anchorWindow.screenFrame.origin

            if Self.eclipsingAlignment == "right" {
                // make the right edge of the Messages window hug the right edge of the Beeper window.
                // this is useful to avoid the window showing through a material in the Beeper window.
                base.x = anchorWindow.screenFrame.maxX - targetSize.width
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

        if #available(macOS 14, *), Defaults.imessage.bool(forKey: DefaultsKeys.eclipsingDebug) {
            Task { @MainActor in
                let debugger = EclipsingDebugger.shared
                debugger.note(EclipsingRect(at: originalMessagesFrame, label: "Original", color: NSColor.systemRed.cgColor))
                debugger.note(EclipsingRect(at: anchorWindow.screenFrame, label: anchorWindow.debugLabel, color: NSColor.systemGray.cgColor))
                debugger.note(EclipsingRect(at: targetRect, label: "Target", color: NSColor.systemGreen.cgColor))
                // i think this is up-to-date by now? might need to wait for a next
                // runloop turn?
                guard let frame = try? messagesWindow.frame() else { return }
                EclipsingDebugger.shared.note(EclipsingRect(at: frame, label: "Final", color: NSColor.systemBlue.cgColor))
            }
        }
    }

    func automationDidComplete(_: Accessibility.Element) throws {
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

    func userManuallyActivated(_: NSRunningApplication) throws {
        hideDebouncer.immediatelyUnhide()
    }

    func userManuallyDeactivated(_: NSRunningApplication) throws {
        hideDebouncer.requestHide()
    }
}

private extension EclipsingWindowCoordinator {
    struct AnchorWindow {
        var description: String
        var debugLabel: String
        var screenFrame: NSRect
        var originalFrame: NSRect?
        var screen: NSScreen?
        var ownerPID: pid_t? = nil
    }

    private static var debouncingPeriod: RunLoop.SchedulerTimeType.Stride { .init(Defaults.imessage.double(forKey: DefaultsKeys.hidingCoordinatorDebounce)) }
    private static var shouldOnlyEclipseIfEncompasses: Bool { Defaults.imessage.bool(forKey: DefaultsKeys.onlyEclipseIfEncompasses) }
    private static var eclipsingOffsetX: CGFloat { Defaults.imessage.double(forKey: DefaultsKeys.eclipsingOffsetX) }
    private static var eclipsingOffsetY: CGFloat { Defaults.imessage.double(forKey: DefaultsKeys.eclipsingOffsetY) }
    private static var eclipsingAlignment: String? { Defaults.imessage.string(forKey: DefaultsKeys.eclipsingAlignment) }

    private static var eclipsingSize: NSSize {
        NSSize(
            width: Defaults.imessage.double(forKey: DefaultsKeys.eclipsingWidth),
            height: Defaults.imessage.double(forKey: DefaultsKeys.eclipsingHeight)
        )
    }

    // Accurate as of macOS 15.3.2.
    static let messagesAppMinimumSize = NSSize(width: 660.0, height: 320.0)

    static func eclipsingAnchorWindow(messagesPID: pid_t?) throws -> AnchorWindow {
        if let window = NSApplication.shared.largestElectronWindow {
            let screenFrame = screenFrame(for: window)
            return AnchorWindow(
                description: "Electron window",
                debugLabel: "Electron",
                screenFrame: screenFrame,
                originalFrame: window.frame,
                screen: window.screen
            )
        }

        if let window = externalEclipsingAnchorWindow(messagesPID: messagesPID) {
            log.notice("falling back to external frontmost window for eclipsing: \(window.description)")
            return window
        }

        throw WindowCoordinatorError.generic(message: "Couldn't find an eclipsing anchor window")
    }

    static func screenFrame(for window: NSWindow) -> NSRect {
        let frame = window.frame
        guard let screen = window.screen else {
            log.warning("can't determine which screen the Electron window is on, using original frame which will result in an unexpected position")
            return frame
        }

        // NSWindow frames are Cocoa coordinates with an origin at bottom-left.
        // Accessibility window positions use the screen coordinate space with an
        // origin at top-left, which matches CGWindow bounds.
        return NSRect(
            origin: NSPoint(x: frame.origin.x, y: screen.frame.height - frame.maxY),
            size: frame.size
        )
    }

    static func externalEclipsingAnchorWindow(messagesPID: pid_t?) -> AnchorWindow? {
        let currentPID = getpid()
        let excludedPIDs = Set([currentPID, messagesPID].compactMap { $0 })
        let windows = externalAnchorWindows(excludingPIDs: excludedPIDs)

        // prefer the frontmost app's largest window; otherwise the largest window
        // of whichever app owns the frontmost on-screen window (z-order order).
        let chosen: AnchorWindow?
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           !excludedPIDs.contains(frontmostPID),
           let frontmostWindow = largestExternalWindow(in: windows, ownerPID: frontmostPID) {
            chosen = frontmostWindow
        } else if let firstWindowOwnerPID = windows.first?.ownerPID {
            chosen = largestExternalWindow(in: windows, ownerPID: firstWindowOwnerPID)
        } else {
            chosen = nil
        }

        // resolve the host screen only for the window we actually return.
        guard var anchor = chosen else { return nil }
        anchor.screen = screen(containing: anchor.screenFrame)
        return anchor
    }

    static func largestExternalWindow(in windows: [AnchorWindow], ownerPID: pid_t) -> AnchorWindow? {
        windows
            .filter { $0.ownerPID == ownerPID }
            .max(by: { $0.screenFrame.area < $1.screenFrame.area })
    }

    static func externalAnchorWindows(excludingPIDs excludedPIDs: Set<pid_t>) -> [AnchorWindow] {
        guard let descriptions = try? Window.listDescriptions(.onScreen, excludeDesktopElements: true) else {
            return []
        }

        return descriptions.compactMap { description -> AnchorWindow? in
            guard !excludedPIDs.contains(description.owner),
                  description.layer == 0,
                  description.alpha > 0
            else {
                return nil
            }

            let frame = NSRectFromCGRect(description.bounds)
            guard frame.width >= Self.messagesAppMinimumSize.width,
                  frame.height >= Self.messagesAppMinimumSize.height
            else {
                return nil
            }

            let ownerName = description.ownerName ?? "unknown"
            // `screen` is resolved later, only for the window we ultimately pick.
            return AnchorWindow(
                description: "\(ownerName) window (pid \(description.owner))",
                debugLabel: ownerName,
                screenFrame: frame,
                originalFrame: nil,
                screen: nil,
                ownerPID: description.owner
            )
        }
    }

    static func screen(containing screenFrame: NSRect) -> NSScreen? {
        let center = NSPoint(x: screenFrame.midX, y: screenFrame.midY)
        return NSScreen.screens.first { screen in
            let topLeftFrame = NSRect(
                origin: NSPoint(x: screen.frame.minX, y: screen.frame.height - screen.frame.maxY),
                size: screen.frame.size
            )
            return topLeftFrame.contains(center)
        }
    }
}

// MARK: - Extensions

private extension NSRect {
    var area: Double { size.area }

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
        let prefix = Defaults.imessage.string(forKey: DefaultsKeys.eclipsingWindowClassNamePrefix) ?? "Electron"
        // XXX: It's likely possible for this read to race with Electron's main thread, or whatever actually owns the window.
        let electronWindows = windows.filter { NSStringFromClass(type(of: $0)).starts(with: prefix) }
        log.debug("found \(electronWindows.count) electron window(s)")

        if Defaults.imessage.bool(forKey: DefaultsKeys.eclipsingUsesLargestWindow) {
            let largest = electronWindows.max(by: { $0.frame.area < $1.frame.area })
            if let largest {
                log.debug("biggest has frame of \(largest.frame) (area: \(largest.frame.area))")
            }
            return largest
        }
        return electronWindows.first
    }
}
