import WindowControl
import AccessibilityControl
import AppKit
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "space-whm")

final class SpacesWindowHidingManager: WHMBase {
    static let canUseUnknownSpace = !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 12, minorVersion: 2, patchVersion: 0))

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
                } else {
                    log.notice("space \($0.raw) was created by us but is visible now")
                    // hide/destroy apparently has no effect atm
                    // $0.hide()
                    // $0.destroy()
                }
            }
            return false
        }.first
        if let existing { log.debug("reusing existing space \(existing.raw)") }
        return try existing ?? Space(newSpaceOfKind: kind)
    }

    private var lastActiveDisplay: Display?
    private var _hiddenSpace: Space
    private var hiddenSpace: Space {
        get throws {
            if Self.canUseUnknownSpace { return _hiddenSpace }
            // if Self.canUseUnknownSpace || !_hiddenSpace.isVisibleInMissionControl { return _hiddenSpace }
            _hiddenSpace = try Self.createOrGetInvisibleUserSpace()
            return _hiddenSpace
        }
    }
    private var dockObserver: Dock.Observer?
    private var ncToken: NSObjectProtocol?

    private var lastActivate: Date?

    // lazy var debouncedOnDidChangeScreenParams = debounced(for: 5) {
    //     // Space.setValues isn't working so we remove the key instead of setting a new value
    //     // not needed when dock process is changed
    //     try? self._hiddenSpace.removeKeys(["canReuse"])
    //     (try? Self.createOrGetInvisibleUserSpace()).map { self._hiddenSpace = $0 }
    //     self.hide()
    // }

    // hiddenSpace will become visible when dock is restarted or display config is changed so create another hidden space and move window
    private func monitorMissionControlChanges() {
        dockObserver = Dock.Observer { [weak self] in
            self?.hide()
        }
        // ncToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
        //     debugLog("ncDidChangeScreenParameters")
        //     self?.debouncedOnDidChangeScreenParams()
        // }
        // if the hidden space is actually visible, activating messages app would cause the active space to change
        ncToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            log.debug("ncActiveSpaceDidChangeNotification")
            if let lastActivate = self?.lastActivate, lastActivate.timeIntervalSinceNow > -1 {
                log.debug("hiding (unhiding) window because space changed after app activate \(lastActivate.timeIntervalSinceNow)")
                self?.hide()
            }
        }
    }

    override init() throws {
        log.debug("can we use unknown spaces? \(Self.canUseUnknownSpace)")
        _hiddenSpace = try Self.canUseUnknownSpace ? Space(newSpaceOfKind: .unknown) : Self.createOrGetInvisibleUserSpace()
        try super.init()
        if !Self.canUseUnknownSpace {
            self.monitorMissionControlChanges()
        }

#if DEBUG && !NO_SPACES
        // the main space has an empty string as uuid/name and 1 as compat id
        // "mission-control", "dock", "NotificationCenter", "SpacesBarWindowController", "SensorIndicators", "ControlCenter", "com.apple.loginUI", "AccessibilityVisualsSpace"
        // are some unknown spaces not present in .allSpaces
        let all = try Space.list(.allOSSpaces)
        log.debug("[spaces] \(all.count) space(s)")
        all.forEach { $0.printAttributes() }
        // all.filter { (try? $0.name()) == "1FBF2F7F-57EC-56E5-521F-556A305D1A61" }.forEach { $0.destroy() }
#endif
    }

    override func appActivated(window: Accessibility.Element?) throws {
        try super.appActivated(window: window)
        lastActivate = Date()
    }

    // returns last active display
    private static func moveWindow(_ windowCG: Window, to space: Space) throws -> Display {
#if NO_SPACES
        return .main
#else
        // FIXME: this doesn't seem to work consistently with multiple displays
        let lastActiveDisplay: Display
        if let lastActiveSpace = try? windowCG.currentSpaces(.allVisibleSpaces).first,
           let activeDisplay = try? Display.allOnline().first(where: { (try? $0.currentSpace()) == lastActiveSpace }) {
            lastActiveDisplay = activeDisplay
        } else {
            lastActiveDisplay = .main
        }
        try windowCG.moveToSpace(space)
        return lastActiveDisplay
#endif
    }

    private func move(window: Accessibility.Element, to space: Space, isHidden: Bool) throws {
        if (try? window.windowIsFullScreen()) == true {
            log.debug("WindowHidingManager.move: window is full screen, not moving")
        } else {
            // this would be an alternative way to hide the window but it changes the active space and doesn't allow us to close/open at will
            // if isHidden { try window.windowIsFullScreen(assign: true) }
            let windowCG = try window.window()
            if isHidden {
                lastActiveDisplay = try Self.moveWindow(windowCG, to: space)
            } else {
                try windowCG.moveToSpace(space)
            }
        }
    }

    override func hide() {
        super.hide()
        try? phtConn?.setMessagesHidden(true)
        if app?.isActive == true {
            return
        }
        mainWindow.map {
            try? self.move(window: $0, to: hiddenSpace, isHidden: true)
            self.afterHide?()
        }
    }

    override func unhide() {
        super.unhide()
        try? phtConn?.setMessagesHidden(false)
        guard let currentSpace = try? lastActiveDisplay?.currentSpace() else {
            log.debug("WindowHidingManager.unhide: current space not found")
            return
        }
        mainWindow.map {
            try? self.move(window: $0, to: currentSpace, isHidden: false)
        }
    }

    override func dispose() {
        log.debug("destroying hiddenSpace")
        try? hiddenSpace.destroy()
    }

    deinit {
        ncToken.map { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        // closing window better than moving back to regular space
        try? mainWindow?.closeWindow()
    }
}

