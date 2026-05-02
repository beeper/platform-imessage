import Foundation

// only exists because `NSMenuItem` needs a target
@available(macOS 13, *)
@MainActor
final class SettingsMenuItemTarget {
    static let shared = SettingsMenuItemTarget()

    @objc func openSettings() {
        SettingsWindowController.reveal()
    }
}
