import AccessibilityControl
import AppKit

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

            guard let lastButton = try window.children().last(where: { el in (try? el.role()) == AXRole.button }) else {
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
}
