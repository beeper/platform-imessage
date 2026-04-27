import AppKit
import SwiftUI

@available(macOS 13, *)
extension SettingsView {
    static let menuItem = {
        var item = NSMenuItem(title: "iMessage Connection Settings…", action: nil, keyEquivalent: "")
        item.target = SettingsMenuItemTarget.shared
        item.action = #selector(SettingsMenuItemTarget.openSettings)
        return item
    }()
}
