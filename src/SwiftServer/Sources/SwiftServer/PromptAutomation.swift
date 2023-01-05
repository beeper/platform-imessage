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
        return try retry(withTimeout: 3, interval: 0.1) {
            let appElement = Accessibility.Element(pid: app.processIdentifier)
            let windows = try appElement.appWindows()
            let window = try windows.first.orThrow(ErrorMessage("window not found"))

            if #available(macOS 13, *) {
                let settingsView = try window.children().first(where: { (try? $0.role()) == AXRole.group }).orThrow(ErrorMessage("settingsView not found"))
                let settingsSplitGroupView = try settingsView.children().first(where: { (try? $0.role()) == AXRole.splitGroup }).orThrow(ErrorMessage("settingsSplitGroupView not found"))

                // right side pane is last
                let settingsPaneView = try settingsSplitGroupView.children().last(where: { (try? $0.role()) == AXRole.group }).orThrow(ErrorMessage("settingsPaneView not found"))
                let settingsPaneGroupView = try settingsPaneView.children().first(where: { (try? $0.role()) == AXRole.group }).orThrow(ErrorMessage("settingsPaneGroupView not found"))
                let scrollView = try settingsPaneGroupView.children().first(where: { (try? $0.role()) == AXRole.scrollArea }).orThrow(ErrorMessage("scrollView not found"))

                if (try? scrollView.children().first?.localizedDescription() as? String) != "Notification Center" {
                    throw ErrorMessage("Not in Notification Center settings")
                }

                try Self.openNotificationSettingsForApp(appName: appName, scrollView: scrollView)

                // Need to reassign this if ever another app is open and we navigate back to the main notification center settings
                var notificationsScrollView = try settingsPaneGroupView.children().first(where: { (try? $0.role()) == AXRole.scrollArea }).orThrow(ErrorMessage("notificationsScrollView not found"))
                var allowNotificationsView = try notificationsScrollView.children().first(where: { (try? $0.role()) == AXRole.group }).orThrow(ErrorMessage("allowNotificationsView not found"))

                if (try? allowNotificationsView.children().last(where: { (try? $0.role()) == AXRole.staticText })?.value() as? String) != appName {
                    debugLog("Not in \(appName) settings, going back to main notification center settings. Current appName:\((try? allowNotificationsView.children().last(where: { (try? $0.role()) == AXRole.staticText })?.value() as? String) ?? "nil")")
                    let toolbarView = try window.children().first(where: { (try? $0.role()) == AXRole.toolbar }).orThrow(ErrorMessage("toolbarView not found"))
                    let toolbarButton = try toolbarView.children().first(where: { (try? $0.role()) == AXRole.button }).orThrow(ErrorMessage("toolbarButton not found"))
                    try toolbarButton.press()

                    try Self.openNotificationSettingsForApp(appName: appName, scrollView: scrollView)

                    notificationsScrollView = try settingsPaneGroupView.children().first(where: { (try? $0.role()) == AXRole.scrollArea }).orThrow(ErrorMessage("notificationsScrollView not found"))
                    allowNotificationsView = try notificationsScrollView.children().first(where: { (try? $0.role()) == AXRole.group }).orThrow(ErrorMessage("allowNotificationsView not found"))
                }

                let notificationsSwitch = try allowNotificationsView.children().first(where: { (try? $0.subrole()) == AXSubrole.switch }).orThrow(ErrorMessage("switch not found"))
                debugLog("notificationsSwitch: \((try? notificationsSwitch.value() as? Bool) ?? false)")
                if (try? notificationsSwitch.value() as? Bool) == true {
                    debugLog("notifications are enabled, disabling")
                    try notificationsSwitch.press()
                    // Closing too soon causes the value to not change
                    sleep(1)
                }
            } else {
                let tabView = try window.children().first(where: { (try? $0.role()) == AXRole.tabGroup }).orThrow(ErrorMessage("tabView not found"))
                let scrollView = try tabView.children().first(where: { (try? $0.role()) == AXRole.scrollArea }).orThrow(ErrorMessage("scrollView not found"))
                let paneView = try tabView.children().first(where: { (try? $0.role()) == AXRole.group }).orThrow(ErrorMessage("paneView not found"))
                let tableView = try scrollView.children().first(where: { (try? $0.role()) == AXRole.table }).orThrow(ErrorMessage("tableView not found"))
                let targetRow = try tableView.children().first(where: {
                    (try? $0.role()) == AXRole.row &&
                        (try? $0.children[0].titleUIElement().value() as? String) == appName
                }).orThrow(ErrorMessage("targetRow not found"))

                try targetRow.isSelected(assign: true)
                guard try targetRow.isSelected() == true else { throw ErrorMessage("targetRow not selected") }

                let notificationsSwitch = try paneView.children().first(where: { (try? $0.subrole()) == AXSubrole.switch }).orThrow(ErrorMessage("switch not found"))
                if (try? notificationsSwitch.value() as? String) == "on" { // unknown if on is localized
                    // .decrement() will turn it off as well but only the switch UI changes, the value remains unchanged
                    try notificationsSwitch.press()
                }
            }

            try? window.windowCloseButton().press()
            return true
        }
    }

    private static func openNotificationSettingsForApp(appName: String, scrollView: Accessibility.Element) throws {
        // App list is always last
        let appsListView = try scrollView.children().last(where: { (try? $0.role()) == AXRole.group }).orThrow(ErrorMessage("appsListView not found"))

        let targetButton = try appsListView.children().first(where: {
            (try? $0.role()) == AXRole.button &&
                (try? $0.localizedDescription().hasPrefix("\(appName), ")) == true
        }).orThrow(ErrorMessage("targetButton not found"))

        // Open Messages Notification Settings
        try targetButton.press()
    }
}
