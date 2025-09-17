import AppKit
import SwiftUI

@available(macOS 13, *)
final class SettingsWindowController: NSWindowController {
    private var settingsController: NSHostingController<SettingsView>?

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
        window.styleMask = [.titled, .closable, .miniaturizable]
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
}
