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
        if try backend.spaces(window) != [target] { try backend.move(window, target) }
        originalSpaces.removeValue(forKey: window)
    }

    /// Restore live windows without resolving a display for closed CG IDs.
    func restoreAll() throws {
        for window in Array(originalSpaces.keys) { try restore(window) }
    }

    /// Resolve the activation destination before clearing recovery records.
    @discardableResult
    func revealAll(to destination: (UInt32) throws -> UInt64) throws -> Bool {
        var movedWindows = false
        for window in Array(originalSpaces.keys) {
            guard try backend.exists(window) else {
                originalSpaces.removeValue(forKey: window)
                continue
            }
            let target = try destination(window)
            guard target != 0, try backend.spaceExists(target) else {
                throw ErrorMessage("Cannot reveal Messages without a visible destination Space")
            }
            if try backend.spaces(window) != [target] {
                try backend.move(window, target)
                movedWindows = true
            }
            // Keep recovery records through the asynchronous Dock handoff.
            // A normal destination becomes the new restoration desktop; the
            // parking Space must never become the background destination.
            if target != hiddenSpace { originalSpaces[window] = target }
        }
        return movedWindows
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
            if let currentApp, !isCurrentAppActive { currentApp.hide() }
        }
    }
    private var currentApp: NSRunningApplication? {
        app.flatMap { NSRunningApplication(processIdentifier: $0.processIdentifier) }
    }

    private var isCurrentAppActive: Bool {
        guard let app = currentApp else { return false }
        let frontmost = Accessibility.Attribute<Bool>.Name(kAXFrontmostAttribute)
        // Completion can run immediately after activation, before AppKit's
        // cached isActive changes. Ask Messages directly before hiding it.
        return (try? Accessibility.Element(pid: app.processIdentifier).attribute(frontmost)()) ?? app.isActive
    }

    var canReuseExtantInstance: Bool { true }
    private let lock = NSRecursiveLock()
    private let session: BridgedSpaceSession
    private var dockPID: pid_t?
    private let owners: BridgedWindowOwners
    private var mainWindowID: UInt32?
    private var automationInProgress = false
    private var activationDeadline = Date.distantPast
    private var activationTimer: DispatchSourceTimer?

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

    private func windowIDsToPark() throws -> [UInt32] {
        guard let app = currentApp else { return [] }
        let windows = try Window.listDescriptions(.all).filter {
            $0.owner == app.processIdentifier && $0.layer == 0
        }
        // Prefer the AX-confirmed main window, but conceal every normal window
        // before unhiding the app. A larger Settings window must not expose the
        // main window while AX discovery catches up. Exclude menu-bar surfaces.
        let axWindows = (try? Accessibility.Element(pid: app.processIdentifier).appWindows()) ?? []
        let axIDs = Set(axWindows.compactMap { try? $0.window().raw })
        let main = windows.first { $0.window.raw == mainWindowID }?.window.raw
        return ([main].compactMap { $0 } + windows.filter {
            $0.window.raw != main && $0.bounds.width > 300 && $0.bounds.height > 100 &&
                (axIDs.contains($0.window.raw) || $0.name?.isEmpty != true)
        }.map { $0.window.raw })
    }

    func prepareAfterLaunch() throws {
        lock.lock()
        defer { lock.unlock() }
        guard currentApp != nil, !isCurrentAppActive else { return }
        var windows: [UInt32] = []
        try Self.waitFor("initial Messages window") {
            windows = try self.windowIDsToPark()
            return !windows.isEmpty
        }
        try parkWindows(windows)
    }

    func makeAutomatable(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            mainWindowID = try trackWindow(window.window().raw)
            guard currentApp != nil, !isCurrentAppActive else { return }
            try parkWindows(windowIDsToPark())
        } catch {
            automationInProgress = false
            try? restoreIdleWindows()
            throw error
        }
    }

    private func parkWindows(_ ids: [UInt32]) throws {
        guard !ids.isEmpty else { return }
        if dockPID != Dock.pid {
            // Dock can expose previously hidden user Spaces. Restore before replacing one.
            currentApp?.hide()
            try session.dispose()
            dockPID = Dock.pid
        }
        do {
            for id in ids {
                let destination = try Self.displayDestination(for: trackWindow(id), owners: owners)
                guard destination != session.hiddenSpace, IMPrivateSPIActiveSpace() != session.hiddenSpace else {
                    throw ErrorMessage("Cannot park Messages on the user's current desktop")
                }
                // Newly launched hidden windows may not have joined a Space yet.
                try session.park(id, originalSpaceIfUnassigned: destination)
            }
            // Unhide only after every normal window has been concealed.
            currentApp?.unhide()
            try Self.waitFor("concealed Messages windows") {
                let onScreen = try Window.listDescriptions(.onScreen)
                return try ids.allSatisfy { id in
                    try Self.spaces(id) == [self.session.hiddenSpace] &&
                        !onScreen.contains { $0.window.raw == id }
                }
            }
        } catch {
            currentApp?.hide()
            throw error
        }
    }

    func prepareForAutomation() throws {
        lock.lock()
        defer { lock.unlock() }
        automationInProgress = true
        do {
            guard currentApp != nil, !isCurrentAppActive else { return }
            // CG discovery works while the idle app is hidden, before AX discovery.
            try parkWindows(windowIDsToPark())
        } catch {
            automationInProgress = false
            try? restoreIdleWindows()
            throw error
        }
    }

    func automationDidComplete(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        automationInProgress = false
        mainWindowID = try trackWindow(window.window().raw)
        try restoreIdleWindows()
    }

    private func restoreIdleWindows() throws {
        guard !automationInProgress, let app = currentApp, !app.isTerminated,
              !isCurrentAppActive, Date() >= activationDeadline else { return }
        // An idle window on the parking Space makes Dock activation switch to
        // that Space. Hide first, then restore membership without exposing it.
        app.hide()
        let appElement = Accessibility.Element(pid: app.processIdentifier)
        try Self.waitFor("hidden Messages before restoring desktop") {
            // NSRunningApplication.isHidden can lag on a worker thread. AX
            // queries the target process directly instead of that cached state.
            try appElement.isHidden() || self.isCurrentAppActive
        }
        guard currentApp != nil, !isCurrentAppActive else { return }
        try session.restoreAll()
    }

    func reset(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        mainWindowID = try trackWindow(window.window().raw)
        try revealForManualControl()
    }

    private func revealForManualControl() throws {
        let moved = try session.revealAll {
            // Managed-display topology can still report the normal desktop
            // while SkyLight has selected our otherwise hidden Space.
            if let hidden = self.session.hiddenSpace, IMPrivateSPIActiveSpace() == hidden { return hidden }
            return try Self.displayDestination(for: $0, owners: owners)
        }
        currentApp?.unhide()
        // Moving a focused window between Spaces can drop activation. Complete
        // this handoff once; already-restored windows do not activate again.
        if moved { currentApp?.activate(options: [.activateAllWindows]) }
    }

    func userManuallyActivated(_: NSRunningApplication) throws {
        lock.lock()
        defer { lock.unlock() }
        if !session.originalSpaces.isEmpty {
            if activationTimer == nil {
                activationDeadline = Date().addingTimeInterval(1.5)
                // Hidden-Space switches are not reliably reported by NSWorkspace.
                // Poll only for this bounded activation handoff, then stop.
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now(), repeating: 0.05)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    do {
                        if Date() >= self.activationDeadline {
                            self.activationTimer?.cancel()
                            self.activationTimer = nil
                            try self.restoreIdleWindows()
                        } else {
                            try self.finishPendingSpaceActivation()
                        }
                    } catch { log.error("Failed to finish Messages activation: \(error)") }
                }
                activationTimer = timer
                timer.resume()
            }
        }
        if isCurrentAppActive {
            try revealForManualControl()
        } else {
            try finishPendingSpaceActivation()
        }
    }

    private func finishPendingSpaceActivation() throws {
        lock.lock()
        defer { lock.unlock() }
        guard Date() < activationDeadline, let hidden = session.hiddenSpace,
              let app = currentApp, !app.isTerminated else { return }
        // React only to the late arrival on our parking Space, never an
        // unrelated desktop switch or a later manual app switch.
        guard IMPrivateSPIActiveSpace() == hidden else { return }
        try revealForManualControl()
        if !isCurrentAppActive { currentApp?.activate(options: [.activateAllWindows]) }
    }

    // Deactivation itself needs no window manipulation. Completion hides and
    // restores after automation; hiding here can race Dock activation events.

    func dispose() throws {
        lock.lock()
        defer { lock.unlock() }
        if !session.originalSpaces.isEmpty, !isCurrentAppActive { currentApp?.hide() }
        if let hidden = session.hiddenSpace,
           IMPrivateSPIActiveSpace() == hidden || (IMPrivateSPICopyManagedDisplaySpaces()?.contains(where: { record in
               guard let current = record["Current Space"] as? [String: Any] else { return false }
               let id = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (current["id64"] as? NSNumber)?.uint64Value
               return id == hidden
           }) == true) {
            if !isCurrentAppActive { try session.restoreAll() }
            // Dock cannot safely destroy a Space during its activation transition.
            // Keep it alive rather than corrupt the user's desktop session.
            return
        }
        try session.dispose()
    }

    deinit {
        activationTimer?.cancel()
        do { try dispose() } catch { log.error("Failed to restore bridged Spaces: \(error)") }
    }
}
