import AppKit
import Foundation
import AccessibilityControl
import WindowControl
import PHTClient
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "whm")

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

class WHMBase: WindowHidingManager {
    let canReuseApp = true
    let isValid = true

    let phtConn: PHTConnection?
    var app: NSRunningApplication?
    var afterHide: (() -> Void)?

    weak var mainWindow: Accessibility.Element?

    func setApp(_ app: NSRunningApplication) {
        self.app = app
    }

    func setAfterHide(fn: @escaping () -> Void) {
        self.afterHide = fn
    }

    func mainWindowChanged(_ window: Accessibility.Element) throws {
        mainWindow = window
        self.hide()
    }

    init() throws {
        if Preferences.isPHTEnabled {
            // ignore pht connection errors
            let phtConn = try? PHTConnection.create(allowInstall: true)
            self.phtConn = phtConn
        } else {
            self.phtConn = nil
        }
    }

    func appActivated(window: Accessibility.Element?) throws {
        unhide()
    }

    func appDeactivated(window: Accessibility.Element?) throws {}

    func hide() { log.notice("whm.hide()") }
    func unhide() { log.notice("whm.unhide()") }

    func dispose() {}
}

// final class RelaunchWindowHidingManager: WindowHidingManager {
//     let canReuseApp = false
//     var isValid = true
//     var invalidate = false

//     override func appActivated(window: Accessibility.Element) throws {
//         debugLog("WindowHidingManager.appActivated: invalidating")
//         invalidate = true
//     }

//     override func appDeactivated(window: Accessibility.Element) throws {
//         isValid = false
//         debugLog("WindowHidingManager.appDeactivated: invalidated")
//     }
// }

// final class RepositionWindowHidingManager: WHMBase {
//     override func hide() {
//         debugLog("whm.hide()")
//         try? phtConn?.setMessagesHidden(true)
//         if app?.isActive == true {
//             return
//         }
//         try? mainWindow.map {
//             print(NSScreen.screens.map { $0.frame })
//             // 1728 x 1117
//             try $0.position(assign: CGPoint(x: 1727, y: 1116))
//         }
//         self.afterHide?()
//     }

//     override func unhide() {
//         debugLog("whm.unhide()")
//         try? phtConn?.setMessagesHidden(false)
//         try? mainWindow.map {
//             try $0.position(assign: CGPoint(x: 0, y: 0))
//         }
//     }
// }

func getBestWHM() throws -> WindowHidingManager {
    try SpacesWindowHidingManager()
}
