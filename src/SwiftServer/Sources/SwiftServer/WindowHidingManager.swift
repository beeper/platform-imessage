import AppKit
import Foundation
import AccessibilityControl
import WindowControl
import PHTClient

protocol WindowHidingManager {
    var isValid: Bool { get }
    var canReuseApp: Bool { get }

    func setApp(_ app: NSRunningApplication)
    func setAfterHide(fn: @escaping () -> Void)

    func hide()
    func unhide()
    func mainWindowChanged(_ mainWindow: Accessibility.Element) throws
    func appActivated(window: Accessibility.Element?) throws
    func appDeactivated(window: Accessibility.Element?) throws
    func dispose()
}

extension Space {
    var isVisibleInMissionControl: Bool {
        self.dockPID != Dock.pid
    }
}

final class SpacesWindowHidingManager: WindowHidingManager {
    static let canUseUnknownSpace = !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 12, minorVersion: 2, patchVersion: 0))
    
    let canReuseApp = true
    var isValid = true

    private var app: NSRunningApplication?
    private var afterHide: (() -> Void)?
    private let phtConn: PHTConnection?

    func setApp(_ app: NSRunningApplication) {
        self.app = app
    }
    func setAfterHide(fn: @escaping () -> Void) {
        self.afterHide = fn
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
            let isSameDock = (dict["dockPID"] as? pid_t) == dockPID // has to be the same dock instance or the space will be visible
            if createdByUs, isSpaceKindUser {
                if isSameDock {
                    $0.dockPID = dockPID
                    return true
                } else {
                    debugLog("space \($0.raw) was created by us and dock has been relaunched (it may be visible now)")
                    // hide/destroy apparently has no effect atm
                    // $0.hide()
                    // $0.destroy()
                }
            }
            return false
        }.first
        if let existing = existing { debugLog("reusing existing space \(existing.raw)") }
        return try existing ?? Space(newSpaceOfKind: kind)
    }

    private var lastActiveDisplay: Display?
    private var _hiddenSpace: Space
    private var hiddenSpace: Space {
        get throws {
            if Self.canUseUnknownSpace || !_hiddenSpace.isVisibleInMissionControl { return _hiddenSpace }
            _hiddenSpace = try Self.createOrGetInvisibleUserSpace()
            return _hiddenSpace
        }
    }
    private var dockObserver: Dock.Observer?

    init() throws {
        if SwiftServer.isPHTEnabled {
            // ignore pht connection errors
            let phtConn = try? PHTConnection.create(allowInstall: true)
            self.phtConn = phtConn
        } else {
            self.phtConn = nil
        }
        debugLog("canUseUnknownSpace \(Self.canUseUnknownSpace)")
        _hiddenSpace = try Self.canUseUnknownSpace ? Space(newSpaceOfKind: .unknown) : Self.createOrGetInvisibleUserSpace()
        if !Self.canUseUnknownSpace {
            dockObserver = Dock.Observer { [self] in
                // hiddenSpace is now visible so create another hidden space and move window
                if let mw = mainWindow {
                    try? self.move(window: mw, to: self.hiddenSpace, isHidden: true)
                }
            }
        }

        #if DEBUG && !NO_SPACES
        // the main space has an empty string as uuid/name and 1 as compat id
        // "mission-control", "dock", "NotificationCenter", "SpacesBarWindowController", "SensorIndicators", "ControlCenter", "com.apple.loginUI", "AccessibilityVisualsSpace"
        // are some unknown spaces not present in .allSpaces
        let all = try Space.list(.allOSSpaces)
        debugLog("[spaces] \(all.count) space(s)")
        all.forEach { $0.printAttributes() }
        // all.filter { (try? $0.name()) == "1FBF2F7F-57EC-56E5-521F-556A305D1A61" }.forEach { $0.destroy() }
        #endif
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
            debugLog("WindowHidingManager.move: window is full screen, not moving")
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

    weak var mainWindow: Accessibility.Element?

    func mainWindowChanged(_ window: Accessibility.Element) throws {
        mainWindow = window
        try self.move(window: window, to: hiddenSpace, isHidden: true)
    }

    func hide() {
        try? phtConn?.setMessagesHidden(true)
        if app?.isActive == true {
            return
        }
        mainWindow.map {
            try? self.move(window: $0, to: hiddenSpace, isHidden: true)
        }
        self.afterHide?()
    }

    func unhide() {
        try? phtConn?.setMessagesHidden(false)
        guard let currentSpace = try? lastActiveDisplay?.currentSpace() else {
            debugLog("WindowHidingManager.unhide: current space not found")
            return
        }
        mainWindow.map {
            try? self.move(window: $0, to: currentSpace, isHidden: false)
        }
    }

    func appActivated(window: Accessibility.Element?) throws {
        unhide()
    }

    func appDeactivated(window: Accessibility.Element?) throws {}

    func dispose() {
        debugLog("destroying hiddenSpace")
        try? hiddenSpace.destroy()
    }

    deinit {
        // closing window better than moving back to regular space
        try? mainWindow?.closeWindow()
    }
}

// final class RelaunchWindowHidingManager: WindowHidingManager {
//     let canReuseApp = false
//     var isValid = true
//     var invalidate = false

//     func mainWindowChanged(_ mainWindow: Accessibility.Element) throws {}

//     func appActivated(window: Accessibility.Element) throws {
//         debugLog("WindowHidingManager.appActivated: invalidating")
//         invalidate = true
//     }

//     func appDeactivated(window: Accessibility.Element) throws {
//         isValid = false
//         debugLog("WindowHidingManager.appDeactivated: invalidated")
//     }
// }

func getBestWHM() throws -> WindowHidingManager {
    try SpacesWindowHidingManager()
}
