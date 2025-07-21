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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("no")
    }
}

@available(macOS 14, *)
@MainActor
public final class EclipsingDebugger {
    public static let shared = EclipsingDebugger()

    private var state: EclipsingDebuggerState
    private var windowController: EclipsingWindowController

    init() {
        self.state = EclipsingDebuggerState()
        self.windowController = EclipsingWindowController()
        self.windowController.state = state
    }

    public func show(on screen: NSScreen) {
        guard let window = windowController.window else {
            log.error("couldn't show: no window")
            return
        }

        windowController.cover(screen: screen)
        window.orderFront(nil)
        log.debug("showed window")
    }

    public func hide() {
        guard let window = windowController.window else {
            log.error("couldn't hide: no window")
            return
        }

        window.orderOut(nil)
        log.debug("hid window")
    }
}

@available(macOS 14, *)
public extension EclipsingDebugger {
    func note(_ point: EclipsingPoint) {
        defer { show(on: .suitableForDebugger) }
        state.points.append(point)
    }

    func note(_ rect: EclipsingRect) {
        defer { show(on: .suitableForDebugger) }
        state.rectangles.append(rect)
    }
}

private extension NSScreen {
    static var suitableForDebugger: NSScreen {
        if let screen = NSApp.largestElectronWindow?.screen {
            return screen
        }

        if let main = NSScreen.main {
            log.warning("don't know what screen electron is on, falling back to main screen")
            return main
        }

        log.error("don't know what screen electron is on, and we don't even have a main screen")
        fatalError("couldn't determine a screen to put the debugger on")
    }
}
