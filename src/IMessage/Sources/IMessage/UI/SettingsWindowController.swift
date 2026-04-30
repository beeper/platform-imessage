import AppKit
import SwiftUI

@available(macOS 13, *)
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    init() {
        let settingsController: NSHostingController = {
            let controller = NSHostingController(rootView: SettingsView())
            controller.sizingOptions = [.standardBounds]
            if #available(macOS 14, *) {
                controller.sceneBridgingOptions = .all
            }
            return controller
        }()
        let window = NSWindow(contentViewController: settingsController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 600, height: 900))
        window.contentMinSize = NSSize(width: 600, height: 900)
        // the window is sometimes titled "Untitled" for some reason, even
        // though the SwiftUI view has a `navigationTitle` and we want to bridge
        // everything
        window.title = SettingsView.windowTitle
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("can't make SettingsWindowController from coder")
    }

    @MainActor
    static func reveal() {
        activateApplication()
        shared.showSettingsWindow()
    }

    @MainActor
    static var isVisible: Bool {
        shared.window?.isVisible == true
    }

    @MainActor
    private static func activateApplication() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if #available(macOS 14, *) {
            app.activate()
        } else {
            app.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    private func showSettingsWindow() {
        guard let window else { return }

        window.makeKeyAndOrderFront(nil)
    }
}
