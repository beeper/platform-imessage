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

            hidingCoordinator.app = app
        }
    }

    private var windowFramePreEclipse: NSRect?
    private var hidingCoordinator: HidingCoordinator

    var canReuseExtantInstance: Bool { true }

    init() {
        hidingCoordinator = HidingCoordinator(debouncingFor: Self.debouncingPeriod)
    }

    func makeAutomatable(_ messagesWindow: Accessibility.Element) throws {
        let largestElectronWindow = try NSApp.largestElectronWindow.orThrow(WindowCoordinatorError.generic(message: "Couldn't find Electron window"))

        if windowFramePreEclipse == nil {
            windowFramePreEclipse = try messagesWindow.frame()
        } else {
            // we already have a known frame, don't overwrite it with the eclisped frame
        }
        let targetSize = Self.minimumMessagesAppSize

        guard largestElectronWindow.frame.size.encompasses(targetSize) || !Self.shouldOnlyEclipseIfEncompasses else {
            log.warning("the largest Electron window's frame \(largestElectronWindow.frame) isn't big enough to encompass the target size \(targetSize), _not_ eclipsing")
            return
        }

        log.notice("eclipsing")
        hidingCoordinator.immediatelyUnhide()
        try messagesWindow.size(assign: targetSize)
        var electronOrigin = largestElectronWindow.frame.origin
        electronOrigin.x += Self.eclipsingOffsetX
        electronOrigin.y += Self.eclipsingOffsetY
        try messagesWindow.position(assign: electronOrigin)
    }

    func automationDidComplete(_ window: Accessibility.Element) throws {
        hidingCoordinator.requestHide()
    }

    func reset(_ window: Accessibility.Element) throws {
        hidingCoordinator.immediatelyUnhide()

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
        hidingCoordinator.immediatelyUnhide()
    }

    func userManuallyDeactivated(_ app: NSRunningApplication) throws {
        hidingCoordinator.requestHide()
    }
}

private extension EclipsingWindowCoordinator {
    private static var debouncingPeriod: RunLoop.SchedulerTimeType.Stride { .init(Defaults.swiftServer.double(forKey: DefaultsKeys.hidingCoordinatorDebounce)) }
    private static var shouldOnlyEclipseIfEncompasses: Bool { Defaults.swiftServer.bool(forKey: DefaultsKeys.onlyEclipseIfEncompasses) }
    private static var eclipsingOffsetX: CGFloat { Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingOffsetX) }
    private static var eclipsingOffsetY: CGFloat { Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingOffsetY) }

    private static var minimumMessagesAppSize: NSSize {
        NSSize(
            width: Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingWidth),
            height: Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingHeight)
        )
    }
}

// MARK: - Extensions

private extension NSRect {
    var area: Double { size.area }

    func encompasses(_ other: CGRect) -> Bool {
        size.encompasses(other.size)
    }
}

private extension NSSize {
    var area: Double { width * height }

    func encompasses(_ other: NSSize) -> Bool {
        width >= other.width && height >= other.height
    }
}

private extension NSApplication {
    var largestElectronWindow: NSWindow? {
        let prefix = Defaults.swiftServer.string(forKey: "BEEPEclipsingWindowClassNamePrefix") ?? "Electron"
        // XXX: It's likely possible for this read to race with Electron's main thread, or whatever actually owns the window.
        let electronWindows = windows.filter { NSStringFromClass(type(of: $0)).starts(with: prefix) }
        log.debug("found \(electronWindows.count) electron window(s)")

        if Defaults.swiftServer.bool(forKey: "BEEPEclipsingUsesLargestWindow") {
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
