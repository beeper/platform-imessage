import WindowControl
import AccessibilityControl
import Cocoa
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "spaces-window-coordinator")

/// `Sendable` is compiler-checked: `app` is `@MainActor`-isolated and the rest of
/// the mutable state lives in one `Protected` box. The box also serializes the
/// Dock/NotificationCenter observer callbacks (which fire on arbitrary threads)
/// against the automation-lane methods — previously those raced.
final class SpacesWindowCoordinator: Sendable {
    @MainActor
    var app: NSRunningApplication?

    private struct MutableState {
        var lastKnownWindow: Accessibility.Element?
        var lastKnownDisplayWindowWasOn: Display?
        var dockObserver: Dock.Observer?
        var notificationCenterObserver: NSObjectProtocol?
        var lastManualActivation: Date?
    }

    private let state = Protected(MutableState())

    // only non-nil if canUseUnknownSpace; assigned once at init. Boxed because
    // `Space` (WindowControl) isn't Sendable; it's only used from the lane and deinit.
    private let unknownSpace: UncheckedSendableBox<Space>?

    /** A space that the Messages window can be moved to in order to conceal it during automation. */
    private var hiddenSpace: Space {
        get throws {
            if let unknownSpace { return unknownSpace.value }
            return try Self.createOrGetInvisibleUserSpace()
        }
    }

    init() throws {
        log.debug(Self.canUseUnknownSpace ? "can use unknown spaces" : "can't use unknown spaces")

        if Self.canUseUnknownSpace || Defaults.imessage.bool(forKey: DefaultsKeys.spacesAlwaysUseUnknownSpace) {
            unknownSpace = UncheckedSendableBox(Space(newSpaceOfKind: .unknown))
        } else {
            unknownSpace = nil
            // have to use a .user space, which behaves differently. observe various things on the system to improve ux
            self.beginObservationsForUserSpace()
        }

        #if DEBUG
        do {
            try debug_printSpaces()
        } catch {
            log.error("[debug] failed to print spaces: \(String(reflecting: error))")
        }
        #endif
    }

    deinit {
        do {
            if Defaults.imessage.bool(forKey: DefaultsKeys.spacesDestroySpaceOnDeinit) {
                try hiddenSpace.destroy()
            }
            let (observer, window) = state.withLock { ($0.notificationCenterObserver, $0.lastKnownWindow) }
            observer.map { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            // closing window better than moving back to regular space
            try window?.closeWindow()
        } catch {
            log.error("failed during deinit: \(String(reflecting: error))")
        }
    }
}

// MARK: - SpacesWindowCoordinator+WindowCoordinator

extension SpacesWindowCoordinator: WindowCoordinator {
    var canReuseExtantInstance: Bool { true }

    func makeAutomatable(_ window: Accessibility.Element) async throws {
        guard await app?.isActive == false else { return }
        state.withLock { $0.lastKnownWindow = window }
        try moveLastKnownWindowToHiddenSpace()
    }

    func reset(_ window: Accessibility.Element) async throws {
        let (lastKnownDisplay, hasLastKnownWindow) = state.withLock {
            ($0.lastKnownDisplayWindowWasOn, $0.lastKnownWindow != nil)
        }
        guard let currentSpace = try? lastKnownDisplay?.currentSpace(), hasLastKnownWindow else {
            log.debug("can't reset, the last known window or current space was missing")
            return
        }

        try (window.window()).moveToSpace(currentSpace)
    }

    @MainActor
    func automationDidComplete() throws {
        // after automating, keep the window on the hidden space
    }

    @MainActor
    func userManuallyActivated(_: NSRunningApplication) throws {
        state.withLock { $0.lastManualActivation = Date() }
    }
}

private extension SpacesWindowCoordinator {
    static var canUseUnknownSpace: Bool {
        // only on <12.2
        let macOS_12_2 = OperatingSystemVersion(majorVersion: 12, minorVersion: 2, patchVersion: 0)
        return !ProcessInfo.processInfo.isOperatingSystemAtLeast(macOS_12_2)
    }

    static func createOrGetInvisibleUserSpace() throws -> Space {
        let allSpaces = try Space.list(.allSpaces)
        let kind = Space.Kind.user
        let existing = allSpaces.filter {
            guard let values = try? $0.values() else { return false }
            guard let dict = values as? [String: AnyObject] else { return false }
            let createdByUs = (dict["uuid"] as? String)?.hasPrefix(Space.prefix) == true
            let isSpaceKindUser = (dict["type"] as? UInt32) == kind.raw.rawValue
            let dockPID = Dock.pid
            if createdByUs, isSpaceKindUser {
                let isSameDock = (dict["dockPID"] as? pid_t) == dockPID // has to be the same dock instance or the space will be visible
                let canReuse = (dict["canReuse"] as? Bool) == true
                if isSameDock, canReuse {
                    $0.dockPID = dockPID
                    return true
                }
                log.notice("space \($0.raw) was created by us but is visible now")
                // hide/destroy apparently has no effect atm
                // $0.hide()
                // $0.destroy()
            }
            return false
        }.first
        if let existing { log.debug("reusing existing space \(existing.raw)") }
        return existing ?? Space(newSpaceOfKind: kind)
    }

    func moveLastKnownWindowToHiddenSpace() throws {
        guard let lastKnownWindow = state.withLock({ $0.lastKnownWindow }) else { return }
        try moveWindowToHiddenSpace(window: lastKnownWindow)
    }

    func moveWindowToHiddenSpace(window: Accessibility.Element) throws {
        guard (try? window.windowIsFullScreen()) != true else {
            log.debug("window is full screen, not moving")
            return
        }

        // this would be an alternative way to hide the window but it changes the active space and doesn't allow us to close/open at will
        // if isHidden { try window.windowIsFullScreen(assign: true) }
        let windowCG = try window.window()

        // FIXME: this doesn't seem to work consistently with multiple displays
        if let spaceWindowIsOn = try? windowCG.currentSpaces(.allVisibleSpaces).first,
           let displayWindowIsOn = try? Display.allOnline().first(where: { (try? $0.currentSpace()) == spaceWindowIsOn }) {
            log.debug("found messages app on display \(displayWindowIsOn.raw)")
            state.withLock { $0.lastKnownDisplayWindowWasOn = displayWindowIsOn }
        } else {
            log.debug("assuming messages app is on main display")
            state.withLock { $0.lastKnownDisplayWindowWasOn = .main }
        }

        try windowCG.moveToSpace(hiddenSpace)
    }

    // if we can't use an .unknown space, then we need to use a .user space, which the user can more easily inadvertently switch to, and it can
    // be made visible if the dock is restarted/display config is changed. listen to some events to smooth the experience
    func beginObservationsForUserSpace() {
        if Defaults.imessage.bool(forKey: DefaultsKeys.spacesObserveDock) {
            // hiddenSpace will become visible when dock is restarted or display config is changed, so create another hidden space and move the window
            let dockObserver = Dock.Observer { [weak self] in
                do {
                    try self?.moveLastKnownWindowToHiddenSpace()
                } catch {
                    log.error("failed to hide last known window in response to dock observation: \(String(reflecting: error))")
                }
            }
            state.withLock { $0.dockObserver = dockObserver }
        }

        if Defaults.imessage.bool(forKey: DefaultsKeys.spacesObserveCurrentSpaceChanges) {
            // if we're notified that the current space has changed and the messages app was recently activated, then the user likely
            // jumped to the (no longer) "hidden" space. move the window to the hidden space to make sure ensure it's visible for the user
            let notificationCenterObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self, let lastManualActivation = state.withLock({ $0.lastManualActivation }) else { return }

                log.debug("receive active space changed notification")

                let timeSinceLastActivation = lastManualActivation.timeIntervalSinceNow
                guard timeSinceLastActivation > -1 else { return }

                do {
                    try moveLastKnownWindowToHiddenSpace()
                } catch {
                    log.error("failed to move window to hidden space in response to notification center observation: \(String(reflecting: error))")
                }
            }
            state.withLock { $0.notificationCenterObserver = notificationCenterObserver }
        }
    }
}

// MARK: - Debugging

extension SpacesWindowCoordinator {
    func debug_printSpaces() throws {
        // the main space has an empty string as uuid/name and 1 as compat id
        // "mission-control", "dock", "NotificationCenter", "SpacesBarWindowController", "SensorIndicators", "ControlCenter", "com.apple.loginUI", "AccessibilityVisualsSpace"
        // are some unknown spaces not present in .allSpaces
        let all = try Space.list(.allOSSpaces)
        log.debug("spaces debug: \(all.count) total space(s), attributes:")
        for space in all {
            space.printAttributes()
        }
    }
}
