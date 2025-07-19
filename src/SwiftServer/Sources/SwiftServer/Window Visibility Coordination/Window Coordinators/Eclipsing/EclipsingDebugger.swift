import AppKit
import SwiftUI
import Logging

private let log = Logger(swiftServerLabel: "eclipsing-debugger")

final class OverlayWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        self.ignoresMouseEvents = true
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = NSWindow.Level(Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        self.collectionBehavior = [.stationary, .fullScreenNone, .transient]
        self.isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSScreen {
    static var screenWithMouse: NSScreen? {
        Self.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }
}

@available(macOS 14, *)
final class EclipsingWindowController: NSWindowController {
    var state: EclipsingDebuggerState? {
        didSet {
            guard let state else { return }
            window?.contentView = NSHostingView(rootView: EclipsingDebuggerView(state: state))
        }
    }

    init() {
        let window = OverlayWindow()
        window.title = "Beeper iMessage Eclipsing Debugger"
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.backgroundColor = .clear
        super.init(window: window)
    }

    func cover(screen: NSScreen) {
        log.debug("moving to \(String(reflecting: screen)) (\(screen.localizedName), \(screen.frame))")
        window?.setFrame(screen.frame, display: true)
    }

    func tryCoveringScreenWithElectron() {
        guard let screen = NSApp.largestElectronWindow?.screen else {
            log.error("don't know what screen the electron window is on")
            return
        }
        cover(screen: screen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("no")
    }
}

@available(macOS 14, *)
@MainActor
final class EclipsingDebugger {
    static var shared = EclipsingDebugger()

    private var state: EclipsingDebuggerState
    private var windowController: EclipsingWindowController

    init() {
        self.state = EclipsingDebuggerState()
        self.windowController = EclipsingWindowController()
        self.windowController.state = state
    }

    func show() {
        guard let window = windowController.window else {
            log.error("couldn't show: no window")
            return
        }

        windowController.tryCoveringScreenWithElectron()
        window.orderFront(nil)
        log.debug("showed window")
    }

    func hide() {
        guard let window = windowController.window else {
            log.error("couldn't hide: no window")
            return
        }

        windowController.tryCoveringScreenWithElectron()
        window.orderOut(nil)
        log.debug("hid window")
    }
}

@available(macOS 14, *)
extension EclipsingDebugger {
    func note(_ point: EclipsingPoint) {
        defer { show() }
        let index = state.points.count
        state.points.append(point)
    }

    func note(_ rect: EclipsingRect) {
        defer { show() }
        let index = state.points.count
        state.rectangles.append(rect)
    }
}
