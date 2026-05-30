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
    /// A fully-resolved eclipse anchor. All AppKit-derived geometry is captured
    /// eagerly at construction (on the main thread, see `eclipsingAnchorWindow`),
    /// so consumers on the background automation queue only read plain values.
    struct AnchorWindow {
        /// Frame in screen/AX space (origin at the top-left of the primary display).
        let screenFrame: NSRect
        /// The original Cocoa frame; only the Electron window has one.
        let originalFrame: NSRect?
        /// Diagnostics only.
        let screen: NSScreen?
        let debugLabel: String
        let description: String

        static func electron(_ window: NSWindow) -> AnchorWindow {
            let frame = EclipsingWindowCoordinator.screenFrame(for: window)
            return AnchorWindow(
                screenFrame: frame,
                originalFrame: window.frame,
                screen: EclipsingWindowCoordinator.screen(containing: frame),
                debugLabel: "Electron",
                description: "Electron window"
            )
        }

        static func external(_ description: Window.Description) -> AnchorWindow {
            let frame = NSRectFromCGRect(description.bounds) // CGWindow bounds are already in screen/AX space
            let name = description.ownerName ?? "unknown"
            return AnchorWindow(
                screenFrame: frame,
                originalFrame: nil,
                screen: EclipsingWindowCoordinator.screen(containing: frame),
                debugLabel: name,
                description: "\(name) window (pid \(description.owner))"
            )
        }
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
        // These reads touch main-thread-affined AppKit state (NSApp.windows,
        // NSWorkspace, NSScreen), but makeAutomatable runs on a background queue.
        try onMain {
            if let window = NSApplication.shared.largestElectronWindow {
                return AnchorWindow.electron(window)
            }

            if let description = externalEclipsingAnchorWindow(messagesPID: messagesPID) {
                let anchor = AnchorWindow.external(description)
                log.notice("falling back to external frontmost window for eclipsing: \(anchor.description)")
                return anchor
            }

            throw WindowCoordinatorError.generic(message: "Couldn't find an eclipsing anchor window")
        }
    }

    /// Runs `work` on the main thread synchronously, without deadlocking if the
    /// caller is already on it.
    private static func onMain<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try work()
        }
        return try DispatchQueue.main.sync(execute: work)
    }

    static func screenFrame(for window: NSWindow) -> NSRect {
        if window.screen == nil {
            log.warning("can't determine which screen the Electron window is on; the eclipse position may be unexpected")
        }
        // NSWindow frames are Cocoa coordinates (origin bottom-left); Accessibility
        // window positions use screen space (origin top-left, matching CGWindow bounds).
        return window.frame.flippedBetweenCocoaAndScreenSpace()
    }

    /// Picks an external on-screen window to eclipse behind when no Beeper/Electron
    /// window is available. Best-effort: it prefers the window most likely to be in
    /// front (the frontmost app's topmost window, else the topmost window overall),
    /// but it can't guarantee z-order for a non-Beeper anchor, so the eclipse may
    /// not fully hide Messages.
    static func externalEclipsingAnchorWindow(messagesPID: pid_t?) -> Window.Description? {
        let excludedPIDs = Set([getpid(), messagesPID].compactMap { $0 })
        let candidates = externalAnchorWindows(excludingPIDs: excludedPIDs) // front-to-back z-order

        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           !excludedPIDs.contains(frontmostPID),
           let frontmostWindow = candidates.first(where: { $0.owner == frontmostPID }) {
            return frontmostWindow
        }
        return candidates.first
    }

    static func externalAnchorWindows(excludingPIDs excludedPIDs: Set<pid_t>) -> [Window.Description] {
        // listDescriptions is resilient to individual malformed windows (it skips them).
        guard let descriptions = try? Window.listDescriptions(.onScreen, excludeDesktopElements: true) else {
            return []
        }

        // NOTE: no size filter here — anchor size adequacy is enforced uniformly for
        // both anchor kinds by the `shouldOnlyEclipseIfEncompasses` guard against the
        // real targetSize in makeAutomatable.
        return descriptions.filter { description in
            !excludedPIDs.contains(description.owner)
                && description.layer == 0
                // skip near-transparent/fading windows that wouldn't actually hide Messages
                && description.alpha >= 0.5
        }
    }

    static func screen(containing screenFrame: NSRect) -> NSScreen? {
        // screenFrame is in screen/AX space (origin top-left); NSScreen frames are
        // Cocoa space (origin bottom-left), so flip the center point before testing.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let cocoaCenter = NSPoint(x: screenFrame.midX, y: primaryHeight - screenFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(cocoaCenter) }
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
