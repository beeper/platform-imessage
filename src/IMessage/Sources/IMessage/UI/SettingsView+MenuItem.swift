import AppKit

// only exists because `NSMenuItem` needs a target
@available(macOS 13, *)
@MainActor
private final class SettingsMenuItemTarget {
    static let shared = SettingsMenuItemTarget()

    @objc func openSettings() {
        SettingsWindowController.reveal()
    }
}

@available(macOS 13, *)
extension SettingsView {
    static let menuItem = {
        var item = NSMenuItem(title: "iMessage Connection Settings…", action: nil, keyEquivalent: "")
        item.target = SettingsMenuItemTarget.shared
        item.action = #selector(SettingsMenuItemTarget.openSettings)
        return item
    }()
}
