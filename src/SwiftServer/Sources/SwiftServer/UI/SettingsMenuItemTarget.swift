import Foundation

// only exists because `NSMenuItem` needs a target
@available(macOS 13, *)
@MainActor
final class SettingsMenuItemTarget {
    static let shared = SettingsMenuItemTarget()
    private lazy var settingsWindowController = SettingsWindowController()

    @objc func openSettings() {
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
    }
}
