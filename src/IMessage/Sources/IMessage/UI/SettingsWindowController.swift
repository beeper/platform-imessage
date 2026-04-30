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
        activateApplication(finishLaunching: false)
        shared.showSettingsWindow()
    }

    @MainActor
    static func revealAndRunEventLoopUntilClosed() {
        activateApplication(finishLaunching: true)
        installCommandMenu()
        shared.showSettingsWindow()
        shared.runEventLoopUntilClosed()
    }

    @MainActor
    private static func activateApplication(finishLaunching: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if finishLaunching {
            app.finishLaunching()
        }
        if #available(macOS 14, *) {
            app.activate()
        } else {
            app.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    private static func installCommandMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    private func showSettingsWindow() {
        guard let window else { return }

        window.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func runEventLoopUntilClosed() {
        guard let window else { return }

        while window.isVisible {
            autoreleasepool {
                if let event = NSApp.nextEvent(
                    matching: .any,
                    until: Date.distantFuture,
                    inMode: .default,
                    dequeue: true
                ) {
                    NSApp.sendEvent(event)
                    NSApp.updateWindows()
                }
            }
        }
    }
}
