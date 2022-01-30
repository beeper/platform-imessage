import Foundation
import AccessibilityControl
import WindowControl

protocol WindowHidingManager {
    var isValid: Bool { get }
    var canReuseApp: Bool { get }

    func mainWindowChanged(_ mainWindow: Accessibility.Element) throws
    func appActivated(window: Accessibility.Element) throws
    func appDeactivated(window: Accessibility.Element) throws
}

extension Space {
    var isVisibleInMissionControl: Bool {
        self.dockPID != Dock.pid
    }
}

let CAN_USE_UNKNOWN_SPACE = !(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 12 && ProcessInfo.processInfo.operatingSystemVersion.minorVersion >= 2)
final class SpacesWindowHidingManager: WindowHidingManager {
    let canReuseApp = true
    var isValid = true

    static func createOrGetInvisibleUserSpace() throws -> Space {
        let allSpaces = try Space.list(.allSpaces)
        let existing = allSpaces.filter {
            guard let values = try? $0.values() else { return false }
            guard let dict = values as? [String: AnyObject] else { return false }
            let createdByUs = (dict["uuid"] as? String)?.hasPrefix("Texts") == true
            let isSpaceKindUser = (dict["type"] as? UInt32) == Space.Kind.user.raw.rawValue
            let isSameDock = (dict["dockPID"] as? pid_t) == Dock.pid // has to be the same dock instance or the space will be visible
            if createdByUs, isSpaceKindUser, !isSameDock {
                debugLog("space \($0.raw) was created by us and dock has been relaunched (it may be visible now)")
                // hide/destroy apparently has no effect atm
                // $0.hide()
                // $0.destroy()
            }
            return createdByUs && isSpaceKindUser && isSameDock
        }.first
        if let existing = existing { debugLog("reusing existing space \(existing.raw)") }
        return try existing ?? Space(newSpaceOfKind: .user)
    }

    private var lastActiveDisplay: Display?
    private var _hiddenSpace: Space
    private var hiddenSpace: Space {
        get throws {
            if CAN_USE_UNKNOWN_SPACE || !_hiddenSpace.isVisibleInMissionControl { return _hiddenSpace }
            _hiddenSpace = try Self.createOrGetInvisibleUserSpace()
            return _hiddenSpace
        }
    }
    private var dockObserver: Dock.Observer?

    init() throws {
        debugLog("CAN_USE_UNKNOWN_SPACE \(CAN_USE_UNKNOWN_SPACE)")
        _hiddenSpace = try CAN_USE_UNKNOWN_SPACE ? Space(newSpaceOfKind: .unknown) : Self.createOrGetInvisibleUserSpace()
        if !CAN_USE_UNKNOWN_SPACE {
            dockObserver = Dock.Observer { [self] in
                // hiddenSpace is now visible so create another hidden space and move window
                if let mw = mainWindow {
                    lastActiveDisplay = try? Self.moveWindow(mw, to: self.hiddenSpace)
                }
            }
        }

        #if DEBUG
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
    private static func moveWindow(_ window: Accessibility.Element, to space: Space) throws -> Display {
        #if NO_SPACES
        return .main
        #else
        let windowCG = try window.window()

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

    weak var mainWindow: Accessibility.Element?

    func mainWindowChanged(_ window: Accessibility.Element) throws {
        mainWindow = window
        lastActiveDisplay = try Self.moveWindow(window, to: hiddenSpace)
    }

    func appActivated(window: Accessibility.Element) throws {
        guard let currentSpace = try? lastActiveDisplay?.currentSpace() else {
            debugLog("WindowHidingManager.appActivated: space not found")
            return
        }
        debugLog("WindowHidingManager.appActivated: moving window")
        try window.window().moveToSpace(currentSpace)
    }

    func appDeactivated(window: Accessibility.Element) throws {
        debugLog("WindowHidingManager.appDeactivated: moving window")
        lastActiveDisplay = try Self.moveWindow(window, to: hiddenSpace)
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
