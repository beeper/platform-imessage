import AppKit
import SwiftUI

/// Window controller for the deep link debug view
@available(macOS 14, *)
public final class DeepLinkDebugWindowController {
    public static let shared = DeepLinkDebugWindowController()

    private var window: NSWindow?

    private init() {}

    /// Show the debug window, creating it if necessary
    @MainActor
    public func show() {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let debugView = DeepLinkDebugView()
        let hostingView = NSHostingView(rootView: debugView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 550),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Deep Link Debug"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DeepLinkDebugWindow")

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Close the debug window
    @MainActor
    public func close() {
        window?.close()
    }

    /// Check if the window is currently visible
    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Show the debug window on launch if the user preference is set
    @MainActor
    public static func showOnLaunchIfNeeded() {
        guard Defaults.swiftServer.bool(forKey: DefaultsKeys.showDeepLinkDebugOnLaunch) else {
            return
        }
        shared.show()
    }
}
