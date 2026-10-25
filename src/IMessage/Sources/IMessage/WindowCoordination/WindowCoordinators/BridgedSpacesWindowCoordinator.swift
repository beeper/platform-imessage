import AppKit
import AccessibilityControl
import IMessageCore
import IMessagePrivateSPI
import Logging
import WindowControl

private let log = Logger(imessageLabel: "bridged-spaces-coordinator")

/// Tracks original membership before issuing a move, including moves whose readback fails.
final class BridgedSpaceSession {
    struct Backend {
        var create: () throws -> UInt64
        var move: (UInt32, UInt64) throws -> Void
        var spaces: (UInt32) throws -> [UInt64]
        var destroy: (UInt64) throws -> Void
        var exists: (UInt32) throws -> Bool = { _ in true }
    }

    private let backend: Backend
    private(set) var hiddenSpace: UInt64?
    private(set) var originalSpaces: [UInt32: UInt64] = [:]

    init(backend: Backend) { self.backend = backend }

    func park(_ window: UInt32, originalSpaceIfUnassigned: UInt64? = nil) throws {
        if hiddenSpace == nil { hiddenSpace = try backend.create() }
        guard let hiddenSpace, hiddenSpace != 0 else { throw ErrorMessage("Could not create hidden Space") }
        let current = try backend.spaces(window)
        if originalSpaces[window] == nil {
            // A sticky/multi-Space window needs a different restoration operation.
            let original = current.count == 1 ? current.first : (current.isEmpty ? originalSpaceIfUnassigned : nil)
            guard let original, original != 0, original != hiddenSpace else {
                throw ErrorMessage("Cannot preserve original window Space membership")
            }
            originalSpaces[window] = original
        }
        if current != [hiddenSpace] { try backend.move(window, hiddenSpace) }
    }

    func restore(_ window: UInt32, to destination: UInt64? = nil) throws {
        guard let original = originalSpaces[window] else { return }
        let target = destination ?? original
        guard target != 0, target != hiddenSpace else {
            throw ErrorMessage("Cannot reveal Messages without a visible destination Space")
        }
        guard try backend.exists(window) else {
            originalSpaces.removeValue(forKey: window)
            return
        }
        try backend.move(window, target)
        originalSpaces.removeValue(forKey: window)
    }

    func dispose() throws {
        // Retain the Space if any restoration fails; destroying it could strand a window.
        for window in Array(originalSpaces.keys) { try restore(window) }
        if let hiddenSpace {
            try backend.destroy(hiddenSpace)
            self.hiddenSpace = nil
        }
    }
}

private final class BridgedWindowOwners {
    var pids: [UInt32: pid_t] = [:]
}

/// Uses the WindowManager bridge rather than relying on an external covering window.
/// All mutations are PID-checked and verified through independent Space readback.
final class BridgedSpacesWindowCoordinator: WindowCoordinator {
    var app: NSRunningApplication?
    var canReuseExtantInstance: Bool { true }
    private let lock = NSRecursiveLock()
    private let session: BridgedSpaceSession
    private var dockPID: pid_t?
    private let owners: BridgedWindowOwners

    init() throws {
        guard let bridge = IMPrivateSPISpaceBridgeCreate() else {
            throw ErrorMessage("SkyLight window-management bridge is unavailable")
        }
        let owners = BridgedWindowOwners()
        self.owners = owners
        session = BridgedSpaceSession(backend: .init(
            create: {
                let space = IMPrivateSPISpaceBridgeCreateSpace(bridge, [
                    "type": 0,
                    "uuid": "Beeper-Bridged-\(UUID().uuidString)",
                    "dockPID": Dock.pid ?? 0,
                ])
                guard space != 0 else { throw ErrorMessage("Bridge refused hidden Space creation") }
                return space
            },
            move: { window, space in
                guard let owner = owners.pids[window],
                      try Window.listDescriptions(.all).contains(where: { $0.window.raw == window && $0.owner == owner }) else {
                    throw ErrorMessage("Refusing to move a window whose owner changed")
                }
                guard IMPrivateSPISpaceBridgeMoveWindow(bridge, window, space) else {
                    throw ErrorMessage("Bridge refused window Space move")
                }
                try Self.waitFor("window Space membership") {
                    try Self.spaces(window) == [space]
                }
            },
            spaces: Self.spaces,
            destroy: { space in
                guard IMPrivateSPISpaceBridgeDestroySpace(bridge, space) else {
                    throw ErrorMessage("Bridge refused Space destruction")
                }
                try Self.waitFor("Space destruction") {
                    try !Space.list(.allOSSpaces).contains { UInt64($0.raw) == space }
                }
            },
            exists: { window in
                guard let owner = owners.pids[window] else { return false }
                return try Window.listDescriptions(.all).contains { $0.window.raw == window && $0.owner == owner }
            }
        ))
        dockPID = Dock.pid
    }

    private static func spaces(_ window: UInt32) throws -> [UInt64] {
        guard let spaces = IMPrivateSPISpacesForWindow(window) else { throw ErrorMessage("Could not read window Spaces") }
        return spaces.map(\.uint64Value)
    }

    private static func waitFor(_ description: String, condition: () throws -> Bool) throws {
        let timeout: TimeInterval = 3
        let pollInterval: TimeInterval = 0.02
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try condition() { return }
            if Thread.isMainThread {
                RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
            } else {
                Thread.sleep(forTimeInterval: pollInterval)
            }
        } while Date() < deadline
        throw ErrorMessage("Timed out verifying \(description)")
    }

    private func checkedWindow(_ element: Accessibility.Element) throws -> UInt32 {
        guard let app, !app.isTerminated else { throw ErrorMessage("No live Messages instance to coordinate") }
        let window = try element.window().raw
        guard try Window.listDescriptions(.all).contains(where: {
            $0.window.raw == window && $0.owner == app.processIdentifier
        }) else { throw ErrorMessage("Refusing to move a window from another process") }
        owners.pids[window] = app.processIdentifier
        return window
    }

    func prepareAfterLaunch(_ window: Accessibility.Element) throws {
        try makeAutomatable(window)
    }

    func makeAutomatable(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let app, NSRunningApplication(processIdentifier: app.processIdentifier)?.isActive != true else { return }
        let id = try checkedWindow(window)
        if dockPID != Dock.pid {
            // Dock can expose previously hidden user Spaces. Restore before replacing one.
            app.hide()
            try session.dispose()
            dockPID = Dock.pid
        }
        do {
            // A newly launched hidden window may not have joined a Space yet.
            // Its normal presentation belongs on the desktop where it was launched.
            try session.park(id, originalSpaceIfUnassigned: IMPrivateSPIActiveSpace())
            // Moving first avoids the old unhide-before-positioning exposure.
            app.unhide()
            try Self.waitFor("concealed Messages window") {
                try Self.spaces(id) == [self.session.hiddenSpace] &&
                    !Window.listDescriptions(.onScreen).contains { $0.window.raw == id }
            }
        } catch {
            app.hide()
            throw error
        }
    }

    func automationDidComplete(_ window: Accessibility.Element) throws {
        try makeAutomatable(window)
    }

    func reset(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        let id = try checkedWindow(window)
        // Bring the window to the user's current desktop, never pull the user
        // back to the desktop captured when automation originally started.
        try session.restore(id, to: IMPrivateSPIActiveSpace())
        app?.unhide()
        // The user already requested activation. Re-activating here can race a
        // subsequent app switch and steal focus or change Spaces a second time.
    }

    func userManuallyDeactivated(_ app: NSRunningApplication) throws {
        // Re-park on the next automation. Moving here can race the activation
        // restoration and bounce the app between active and inactive states.
        if NSRunningApplication(processIdentifier: app.processIdentifier)?.isActive != true { app.hide() }
    }

    func dispose() throws {
        lock.lock()
        defer { lock.unlock() }
        // Cleanup may restore membership on another desktop. Keep that move
        // hidden so shutdown cannot expose or activate the restored window.
        if !session.originalSpaces.isEmpty { app?.hide() }
        try session.dispose()
    }

    deinit {
        do { try dispose() } catch { log.error("Failed to restore bridged Spaces: \(error)") }
    }
}
