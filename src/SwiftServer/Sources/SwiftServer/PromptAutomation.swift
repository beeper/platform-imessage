import AccessibilityControl
import AppKit

// func sendMouseClick(at point: CGPoint, to pid: pid_t) throws {
//     for mouseType in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
//         let ev = try CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: .left)
//             .orThrow(ErrorMessage("Could not create mouse event"))
//         ev.postToPid(pid)
//     }
// }

enum PromptAutomation {
    static func confirmUNCPrompt() throws {
        debugLog("confirmUNCPrompt")
        try retry(withTimeout: 2.5, interval: 0.05) { () throws -> Void in
            debugLog("confirmUNCPrompt attempt")
            guard let uncApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.UserNotificationCenter").first else {
                throw ErrorMessage("unc app not found")
            }
            let appElement = Accessibility.Element(pid: uncApp.processIdentifier)

            let windows = try appElement.appWindows()
            guard windows.count > 0 else { throw ErrorMessage("no windows found") }

            #if DEBUG
            let checkString = "iTerm"
            #else
            let checkString = "Texts requires access to"
            #endif
            guard let window = windows.first(where: { window in
                (try? window.children().contains(where: { child in
                    ((try? child.value() as? String).map { $0.contains(checkString) }) == true
                })) == true
            }) else { throw ErrorMessage("window not found") }

            guard let lastButton = try window.children().last(where: { (try? $0.role()) == AXRole.button }) else {
                throw ErrorMessage("no buttons found")
            }

            try lastButton.press()
            debugLog("last button pressed")
        }
    }

    static func confirmDirectoryAccess(buttonTitle: String) throws {
        debugLog("confirmDirectoryAccess")
        try retry(withTimeout: 2.5, interval: 0.05) { () throws -> Void in
            debugLog("confirmDirectoryAccess attempt")
            let appElement = Accessibility.Element(pid: NSRunningApplication.current.processIdentifier)
            let windows = try appElement.appWindows()
            guard windows.count > 0 else { throw ErrorMessage("no windows found") }

            let isGrantButton = { (el: Accessibility.Element) in (try? el.role()) == AXRole.button && (try? el.title()) == buttonTitle }
            guard let window = windows.first(where: {
                (try? $0.children().contains(where: isGrantButton)) == true
            }) else { throw ErrorMessage("window not found") }

            guard let grantButton = try window.children().last(where: isGrantButton) else { throw ErrorMessage("grant button not found") }
            try grantButton.press()
            debugLog("grant button pressed")
        }
    }

    static func disableNotificationsForApp(named appName: String) throws -> Bool {
        let app = try NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!,
            options: [.withoutActivation], // .andHide shows a gray background and doesn't render the UI
            configuration: [:]
        )
        try app.waitForLaunch()
        return try retry(withTimeout: 2, interval: 0.1) {
            let appElement = Accessibility.Element(pid: app.processIdentifier)
            let windows = try appElement.appWindows()
            let window = try windows.first.orThrow(ErrorMessage("window not found"))
            let tabView = try window.children().first(where: { (try? $0.role()) == AXRole.tabGroup }).orThrow(ErrorMessage("tabView not found"))
            let scrollView = try tabView.children().first(where: { (try? $0.role()) == AXRole.scrollArea }).orThrow(ErrorMessage("scrollView not found"))
            let paneView = try tabView.children().first(where: { (try? $0.role()) == AXRole.group }).orThrow(ErrorMessage("paneView not found"))
            let tableView = try scrollView.children().first(where: { (try? $0.role()) == AXRole.table }).orThrow(ErrorMessage("tableView not found"))
            let targetRow = try tableView.children().first(where: {
                (try? $0.role()) == AXRole.row &&
                    (try? $0.children.value(at: 0).titleUIElement().value() as? String) == appName
            }).orThrow(ErrorMessage("targetRow not found"))

            try targetRow.isSelected(assign: true)
            guard try targetRow.isSelected() == true else { throw ErrorMessage("targetRow not selected") }

            let notificationsSwitch = try paneView.children().first(where: { (try? $0.subrole()) == AXSubrole.switch }).orThrow(ErrorMessage("switch not found"))
            if (try? notificationsSwitch.value() as? String) == "on" { // unknown if on is localized
                // .decrement() will turn it off as well but only the switch UI changes, the value remains unchanged
                try notificationsSwitch.press()
            }

            try? window.windowCloseButton().press()
            return true
        }
    }
}
