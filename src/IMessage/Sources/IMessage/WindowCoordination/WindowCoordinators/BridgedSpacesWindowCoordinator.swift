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
        var spaceExists: (UInt64) throws -> Bool = { _ in true }
        var fallbackSpace: (UInt32) throws -> UInt64? = { _ in nil }
    }

    private let backend: Backend
    private(set) var hiddenSpace: UInt64?
    private(set) var originalSpaces: [UInt32: UInt64] = [:]

    init(backend: Backend) { self.backend = backend }

    func park(_ window: UInt32, originalSpaceIfUnassigned: UInt64? = nil) throws {
        // Display changes and external deletion can remove the Space without
        // restarting Dock. Keep recovery records, but never reuse a dead ID.
        if let hiddenSpace, try !backend.spaceExists(hiddenSpace) { self.hiddenSpace = nil }
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
        guard try backend.exists(window) else {
            originalSpaces.removeValue(forKey: window)
            return
        }
        let target: UInt64
        if let destination {
            target = destination
        } else if try backend.spaceExists(original) {
            target = original
        } else {
            guard let fallback = try backend.fallbackSpace(window) else {
                throw ErrorMessage("Original desktop disappeared and no replacement is available")
            }
            target = fallback
        }
        guard target != 0, target != hiddenSpace, try backend.spaceExists(target) else {
            throw ErrorMessage("Cannot reveal Messages without a visible destination Space")
        }
        try backend.move(window, target)
        originalSpaces.removeValue(forKey: window)
    }

    /// Restore live windows without resolving a display for closed CG IDs.
    func restoreAll() throws {
        for window in Array(originalSpaces.keys) { try restore(window) }
    }

    func dispose() throws {
        // Retain the Space if any restoration fails; destroying it could strand a window.
        try restoreAll()
        if let hiddenSpace {
            if try backend.spaceExists(hiddenSpace) { try backend.destroy(hiddenSpace) }
            self.hiddenSpace = nil
        }
    }
}

struct BridgedDisplaySpace {
    let identifier: String
    let space: UInt64
    let bounds: CGRect

    static func destination(preferredDisplay: String?, windowFrame: CGRect, displays: [Self]) -> Self? {
        if let preferredDisplay, let remembered = displays.first(where: { $0.identifier == preferredDisplay }) {
            return remembered
        }
        // A disconnected display has no destination. Use the surviving display
        // containing most of the relocated window, rather than a global Space ID.
        return displays.max { left, right in
            let leftIntersection = left.bounds.intersection(windowFrame)
            let rightIntersection = right.bounds.intersection(windowFrame)
            let leftArea = leftIntersection.isNull ? 0 : leftIntersection.width * leftIntersection.height
            let rightArea = rightIntersection.isNull ? 0 : rightIntersection.width * rightIntersection.height
            return leftArea < rightArea
        }
    }
}

private final class BridgedWindowOwners {
    var pids: [UInt32: pid_t] = [:]
    var displays: [UInt32: String] = [:]
}

/// Uses the WindowManager bridge rather than relying on an external covering window.
/// All mutations are PID-checked and verified through independent Space readback.
final class BridgedSpacesWindowCoordinator: WindowCoordinator {
    var app: NSRunningApplication? {
        didSet {
            if let currentApp, !currentApp.isActive { currentApp.hide() }
        }
    }
    private var currentApp: NSRunningApplication? {
        app.flatMap { NSRunningApplication(processIdentifier: $0.processIdentifier) }
    }

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
                guard let owner = owners.pids[window],
                      NSRunningApplication(processIdentifier: owner)?.isTerminated == false else { return false }
                return try Window.listDescriptions(.all).contains { $0.window.raw == window && $0.owner == owner }
            },
            spaceExists: { space in
                try Space.list(.allOSSpaces).contains { UInt64($0.raw) == space }
            },
            fallbackSpace: { window in
                try Self.displayDestination(for: window, owners: owners)
            }
        ))
        dockPID = Dock.pid
    }

    private static func spaces(_ window: UInt32) throws -> [UInt64] {
        guard let spaces = IMPrivateSPISpacesForWindow(window) else { throw ErrorMessage("Could not read window Spaces") }
        return spaces.map(\.uint64Value)
    }

    private static func displayDestination(for window: UInt32, owners: BridgedWindowOwners) throws -> UInt64 {
        guard let owner = owners.pids[window],
              let description = try Window.listDescriptions(.all).first(where: { $0.window.raw == window && $0.owner == owner }),
              let topology = IMPrivateSPICopyManagedDisplaySpaces() else {
            throw ErrorMessage("Could not resolve the Messages window's display")
        }
        let online = try Display.allOnline()
        let displays: [BridgedDisplaySpace] = topology.compactMap { record in
            guard let identifier = record["Display Identifier"] as? String,
                  let current = record["Current Space"] as? [String: Any],
                  let space = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (current["id64"] as? NSNumber)?.uint64Value,
                  space != 0 else { return nil }
            let bounds: CGRect
            if identifier == "Main" {
                // Shared-Spaces mode has one record for all physical displays.
                bounds = online.reduce(CGRect.null) { $0.union(CGDisplayBounds($1.raw)) }
            } else {
                guard let display = online.first(where: {
                    guard let uuid = CGDisplayCreateUUIDFromDisplayID($0.raw)?.takeRetainedValue() else { return false }
                    return UUID(cfUUID: uuid).uuidString.caseInsensitiveCompare(identifier) == .orderedSame
                }) else { return nil }
                bounds = CGDisplayBounds(display.raw)
            }
            return BridgedDisplaySpace(identifier: identifier, space: space, bounds: bounds)
        }
        guard let destination = BridgedDisplaySpace.destination(
            preferredDisplay: owners.displays[window],
            windowFrame: description.bounds,
            displays: displays
        ) else { throw ErrorMessage("No desktop is available for the Messages window") }
        owners.displays[window] = destination.identifier
        return destination.space
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

    private func trackWindow(_ window: UInt32) throws -> UInt32 {
        guard let app = currentApp, !app.isTerminated else { throw ErrorMessage("No live Messages instance to coordinate") }
        guard try Window.listDescriptions(.all).contains(where: {
            $0.window.raw == window && $0.owner == app.processIdentifier
        }) else { throw ErrorMessage("Refusing to move a window from another process") }
        owners.pids[window] = app.processIdentifier
        if session.originalSpaces[window] == nil {
            owners.displays.removeValue(forKey: window)
        }
        return window
    }

    func prepareAfterLaunch() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let app = currentApp, !app.isActive else { return }
        // Hiding before AX discovery can make Messages' AX windows unavailable.
        // Find its CG window while hidden, park it, and only then unhide for AX.
        var window: UInt32?
        let minimumWidth: CGFloat = 300
        try Self.waitFor("initial Messages window") {
            let candidates = try Window.listDescriptions(.all).filter {
                $0.owner == app.processIdentifier && $0.layer == 0 && $0.bounds.width > minimumWidth
            }
            let largest = candidates.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            window = largest?.window.raw
            return window != nil
        }
        guard let window else { throw ErrorMessage("No initial Messages window") }
        try parkWindow(trackWindow(window))
    }

    func makeAutomatable(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        guard currentApp?.isActive == false else { return }
        try parkWindow(trackWindow(window.window().raw))
    }

    private func parkWindow(_ id: UInt32) throws {
        if dockPID != Dock.pid {
            // Dock can expose previously hidden user Spaces. Restore before replacing one.
            currentApp?.hide()
            try session.dispose()
            dockPID = Dock.pid
        }
        do {
            // A newly launched hidden window may not have joined a Space yet.
            // Its normal presentation belongs on the desktop where it was launched.
            try session.park(id, originalSpaceIfUnassigned: Self.displayDestination(for: id, owners: owners))
            // Moving first avoids the old unhide-before-positioning exposure.
            currentApp?.unhide()
            try Self.waitFor("concealed Messages window") {
                try Self.spaces(id) == [self.session.hiddenSpace] &&
                    !Window.listDescriptions(.onScreen).contains { $0.window.raw == id }
            }
        } catch {
            currentApp?.hide()
            throw error
        }
    }

    func prepareForAutomation() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let app = currentApp, !app.isActive else { return }
        // AX may not expose the window while the idle app is hidden. Park its
        // CG window before unhiding, so discovering it never flashes onscreen.
        let candidates = try Window.listDescriptions(.all).filter {
            $0.owner == app.processIdentifier && $0.layer == 0 && $0.bounds.width > 300
        }
        if let window = candidates.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
            try parkWindow(trackWindow(window.window.raw))
        }
    }

    func automationDidComplete(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let app = currentApp, !app.isActive else { return }
        // An idle window on the parking Space makes Dock activation switch to
        // that Space. Hide first, then restore membership without exposing it.
        app.hide()
        let appElement = Accessibility.Element(pid: app.processIdentifier)
        try Self.waitFor("hidden Messages before restoring desktop") {
            // NSRunningApplication.isHidden can lag on a worker thread. AX
            // queries the target process directly instead of that cached state.
            try appElement.isHidden() || self.currentApp?.isActive == true
        }
        guard currentApp?.isActive == false else { return }
        try session.restoreAll()
    }

    func reset(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        let id = try trackWindow(window.window().raw)
        // Bring the window to the user's current desktop, never pull the user
        // back to the desktop captured when automation originally started.
        try session.restore(id, to: Self.displayDestination(for: id, owners: owners))
        currentApp?.unhide()
        // The user already requested activation. Re-activating here can race a
        // subsequent app switch and steal focus or change Spaces a second time.
    }

    func userManuallyActivated(_ app: NSRunningApplication) throws {
        lock.lock()
        defer { lock.unlock() }
        guard currentApp?.isActive == true else { return }
        // Usually empty because completion restores the idle window. This also
        // handles a user activation that interrupts an automation operation.
        try session.restoreAll()
        currentApp?.unhide()
    }

    // Deactivation itself needs no window manipulation. Completion hides and
    // restores after automation; hiding here can race Dock activation events.

    func dispose() throws {
        lock.lock()
        defer { lock.unlock() }
        if !session.originalSpaces.isEmpty { currentApp?.hide() }
        try session.dispose()
    }

    deinit {
        do { try dispose() } catch { log.error("Failed to restore bridged Spaces: \(error)") }
    }
}
