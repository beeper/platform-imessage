import AppKit
import Darwin
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
        var exists: (UInt32) throws -> Bool = { _ in true }
        var spaceExists: (UInt64) throws -> Bool = { _ in true }
        var fallbackSpace: (UInt32) throws -> UInt64? = { _ in nil }
        var isOwnedParkingSpace: (UInt64) throws -> Bool = { _ in false }
    }

    private let backend: Backend
    private(set) var hiddenSpace: UInt64?
    private(set) var originalSpaces: [UInt32: UInt64] = [:]

    init(backend: Backend) {
        self.backend = backend
    }

    func park(_ window: UInt32, originalSpaceIfUnassigned: UInt64? = nil) throws {
        // Display changes and external deletion can remove the Space without
        // restarting Dock. Keep recovery records, but never reuse a dead ID.
        if let hiddenSpace, try !backend.spaceExists(hiddenSpace) { self.hiddenSpace = nil }
        if hiddenSpace == nil { hiddenSpace = try backend.create() }
        guard let hiddenSpace, hiddenSpace != 0 else { throw ErrorMessage("Could not create hidden Space") }
        let current = try backend.spaces(window)
        if originalSpaces[window] == nil {
            // A sticky/multi-Space window needs a different restoration operation.
            let original: UInt64?
            let alreadyParked = try current.count == 1 &&
                (current.first == hiddenSpace || backend.isOwnedParkingSpace(current[0]))
            if current.isEmpty || alreadyParked {
                // A reused Messages process may already be parked by a host
                // that exited. Recover to the current ordinary desktop.
                original = try originalSpaceIfUnassigned ?? backend.fallbackSpace(window)
            } else {
                original = current.count == 1 ? current.first : nil
            }
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

    /// Resolve each live window's destination before discarding its recovery record.
    @discardableResult
    func revealAll(to destination: (UInt32) throws -> UInt64) throws -> Bool {
        var movedWindows = false
        for window in Array(originalSpaces.keys) {
            guard try backend.exists(window) else {
                originalSpaces.removeValue(forKey: window)
                continue
            }
            let target = try destination(window)
            let current = try backend.spaces(window)
            try restore(window, to: target)
            movedWindows = movedWindows || current != [target]
        }
        return movedWindows
    }

    func dispose() throws {
        try restoreAll()
        // Release this session's reference; the shared Space survives host exits.
        hiddenSpace = nil
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

/// Parks foreign Messages windows in a reusable, intrinsically unknown Space.
/// Unlike user Spaces this Space is never a Mission Control desktop, even after
/// Dock restarts. Window ownership and complete membership are verified on moves.
final class BridgedSpacesWindowCoordinator: WindowCoordinator {
    private let targetApp = Protected<NSRunningApplication?>(nil)

    @MainActor
    var app: NSRunningApplication? {
        get { targetApp.read() }
        set {
            targetApp.withLock { $0 = newValue }
            // Conceal the process as soon as ownership is acquired, before
            // controller initialization starts discovering its windows.
            do {
                try ensureTargetLease()
                if !isCurrentAppActive { currentApp?.hide() }
            } catch {
                // prepareAfterLaunch retries and reports lease failures before
                // any window operations. A competing owner is left untouched.
                log.debug("Could not acquire Messages window ownership: \(error)")
            }
        }
    }
    private var targetLease: WindowCoordinationFileLock?
    private var leasedPID: pid_t?
    private var currentApp: NSRunningApplication? {
        guard let original = targetApp.read(), !original.isTerminated else { return nil }
        return Self.liveMessagesApp(original.processIdentifier)
    }

    private func ensureTargetLease() throws {
        guard let app = currentApp else { throw ErrorMessage("No live Messages instance to coordinate") }
        if let leasedPID {
            guard leasedPID == app.processIdentifier else { throw ErrorMessage("Messages coordinator cannot change processes") }
            return
        }
        targetLease = try WindowCoordinationFileLock(name: "messages-\(app.processIdentifier)", wait: false)
        leasedPID = app.processIdentifier
    }
    private var isCurrentAppActive: Bool {
        guard let app = currentApp else { return false }
        let frontmost = Accessibility.Attribute<Bool>.Name(kAXFrontmostAttribute)
        return (try? Accessibility.Element(pid: app.processIdentifier).attribute(frontmost)()) ?? app.isActive
    }

    private let lock = NSRecursiveLock()
    private let session: BridgedSpaceSession
    private let owners: BridgedWindowOwners
    private var mainWindowID: UInt32?
    private var disposed = false

    init() throws {
        guard let bridge = IMPrivateSPISpaceBridgeCreate() else {
            throw ErrorMessage("SkyLight window-management bridge is unavailable")
        }
        let owners = BridgedWindowOwners()
        self.owners = owners
        session = BridgedSpaceSession(backend: .init(
            create: { try PersistentUnknownSpace.acquire(bridge: bridge) },
            move: { window, target in
                try Self.verifyOwner(window, owners: owners)
                guard let rawTarget = Int(exactly: target), let targetSpace = Space(raw: rawTarget) else { throw ErrorMessage("Invalid target Space") }
                if try targetSpace.kind() == .unknown {
                    guard try PersistentUnknownSpace.isReusable(target) else {
                        throw ErrorMessage("Refusing to park in an unrecognized unknown Space")
                    }
                    guard IMPrivateSPISpaceBridgeAddWindowToUnknownSpace(bridge, window, target) else {
                        throw ErrorMessage("Bridge refused unknown Space membership")
                    }
                } else {
                    guard IMPrivateSPISpaceBridgeMoveWindow(bridge, window, target) else {
                        throw ErrorMessage("Bridge refused window Space restoration")
                    }
                }
                // Adding unknown membership and managed restoration can both
                // retain old memberships. Verify the new one before removing any.
                try Self.waitFor("target Space membership") {
                    try Self.verifyOwner(window, owners: owners)
                    return try Self.spaces(window).contains(target)
                }
                let others = try Self.spaces(window).filter { $0 != target }
                if !others.isEmpty {
                    try Self.verifyOwner(window, owners: owners)
                    guard IMPrivateSPISpaceBridgeRemoveWindowFromSpaces(bridge, window, others.map { NSNumber(value: $0) }) else {
                        throw ErrorMessage("Bridge refused removal of old Space memberships")
                    }
                }
                try Self.waitFor("exclusive window Space membership") {
                    try Self.verifyOwner(window, owners: owners)
                    return try Self.spaces(window) == [target]
                }
            },
            spaces: Self.spaces,
            exists: { window in
                guard let owner = owners.pids[window] else { return false }
                return try Self.ownedWindow(window, pid: owner) != nil
            },
            spaceExists: { id in try Space.list(.allOSSpaces).contains { UInt64(exactly: $0.raw) == id } },
            fallbackSpace: { try Self.displayDestination(for: $0, owners: owners) },
            isOwnedParkingSpace: PersistentUnknownSpace.isReusable
        ))
    }

    private static func liveMessagesApp(_ pid: pid_t) -> NSRunningApplication? {
        guard kill(pid, 0) == 0 || errno != ESRCH,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated, app.bundleIdentifier == messagesBundleID else { return nil }
        return app
    }

    private static func ownedWindow(_ window: UInt32, pid: pid_t) throws -> Window.Description? {
        guard liveMessagesApp(pid) != nil else { return nil }
        return try Window.listDescriptions(.all).first { $0.window.raw == window && $0.owner == pid }
    }

    private static func verifyOwner(_ window: UInt32, owners: BridgedWindowOwners) throws {
        guard let owner = owners.pids[window], try ownedWindow(window, pid: owner) != nil else {
            throw ErrorMessage("Refusing to move a window whose owner changed")
        }
    }

    private static func spaces(_ window: UInt32) throws -> [UInt64] {
        guard let spaces = IMPrivateSPISpacesForWindow(window) else { throw ErrorMessage("Could not read window Spaces") }
        return spaces.map(\.uint64Value)
    }

    private static func displayDestination(for window: UInt32, owners: BridgedWindowOwners) throws -> UInt64 {
        guard let owner = owners.pids[window],
              let description = try ownedWindow(window, pid: owner),
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

    private static func waitFor(_ description: String, timeout: TimeInterval = 3, condition: () throws -> Bool) throws {
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
        guard let app = currentApp else { throw ErrorMessage("No live Messages instance to coordinate") }
        guard try Self.ownedWindow(window, pid: app.processIdentifier) != nil else {
            throw ErrorMessage("Refusing to move a window from another process")
        }
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
        guard !disposed, currentApp != nil else { return }
        try ensureTargetLease()
        if try windowIDsToPark().isEmpty, let app = currentApp {
            // A reused process can outlive its last window. Ask that exact
            // process to reopen one before waiting for discovery and parking.
            try MessagesInstanceTarget.sendDeepLink(MessagesDeepLink.compose.url(), to: app)
        }
        if isCurrentAppActive {
            // Adopt a reused process left parked by a previous host, without
            // altering an already-visible Messages window under manual control.
            for id in try windowIDsToPark() {
                let current = try Self.spaces(id)
                if current.count == 1, let space = current.first,
                   try PersistentUnknownSpace.isReusable(space) {
                    try session.park(trackWindow(id), originalSpaceIfUnassigned: Self.displayDestination(for: id, owners: owners))
                }
            }
            try revealForManualControl()
            return
        }
        var windows: [UInt32] = []
        try Self.waitFor("initial Messages window") {
            windows = try self.windowIDsToPark()
            return !windows.isEmpty
        }
        try parkWindows(windows)
        // Do not let the controller's recovery getter send another compose URL
        // while the newly unhidden scene is still publishing its AX hierarchy.
        guard let app = currentApp else { throw ErrorMessage("Messages exited during startup") }
        let elements = MessagesAppElements(runningApp: app, openDeepLink: { deepLink in
            try await MessagesController.openDeepLink(deepLink, targeting: app)
        })
        try Self.waitFor("parked Messages AX main window", timeout: 5) {
            guard let main = elements.getMainWindow(), let id = try? main.window().raw else { return false }
            guard try Self.spaces(id) == [self.session.hiddenSpace] else { return false }
            self.mainWindowID = try self.trackWindow(id)
            return true
        }
    }

    func makeAutomatable(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed else { throw ErrorMessage("Messages coordinator was disposed") }
        try parkForAutomation(mainWindow: window)
    }

    private func unhideIfNeeded() {
        guard let app = currentApp else { return }
        if (try? Accessibility.Element(pid: app.processIdentifier).isHidden()) ?? app.isHidden { app.unhide() }
    }

    private func parkWindows(_ ids: [UInt32]) throws {
        guard !ids.isEmpty else { return }
        do {
            var pending = ids
            var parked = Set<UInt32>()
            let deadline = Date().addingTimeInterval(3)
            while !pending.isEmpty {
                for id in pending {
                    let destination = try Self.displayDestination(for: trackWindow(id), owners: owners)
                    if let hidden = session.hiddenSpace {
                        guard IMPrivateSPIActiveSpace() != hidden else {
                            throw ErrorMessage("Cannot park Messages on the user's current Space")
                        }
                    }
                    let current = try Self.spaces(id)
                    if current.count == 1, let source = current.first,
                       IMPrivateSPISpaceType(source) == 3, !(try PersistentUnknownSpace.isReusable(source)) {
                        throw ErrorMessage("Refusing to adopt a window in an unrecognized unknown Space")
                    }
                    try session.park(id, originalSpaceIfUnassigned: destination)
                    parked.insert(id)
                }
                pending = try windowIDsToPark().filter { !parked.contains($0) }
                if !pending.isEmpty, Date() >= deadline { throw ErrorMessage("Messages keeps creating unparked windows") }
            }
            // All normal windows, including Settings, are parked before unhide.
            unhideIfNeeded()
            try Self.waitFor("concealed Messages windows") {
                let visible = try Window.listDescriptions(.onScreen)
                let currentIDs = try self.windowIDsToPark()
                return try currentIDs.allSatisfy { id in
                    try Self.spaces(id) == [self.session.hiddenSpace] &&
                        !visible.contains { $0.window.raw == id }
                }
            }
        } catch {
            currentApp?.hide()
            throw error
        }
    }

    private func parkForAutomation(mainWindow: Accessibility.Element? = nil) throws {
        try ensureTargetLease()
        if let mainWindow { mainWindowID = try trackWindow(mainWindow.window().raw) }
        guard currentApp != nil, !isCurrentAppActive else { return }
        // Keep every normal window parked and AX-accessible between operations.
        try parkWindows(windowIDsToPark())
    }

    func prepareForAutomation() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed else { throw ErrorMessage("Messages coordinator was disposed") }
        try parkForAutomation()
    }

    func automationDidComplete() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed else { return }
        try parkForAutomation()
    }

    func reset(_ window: Accessibility.Element) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed else { return }
        try ensureTargetLease()
        mainWindowID = try trackWindow(window.window().raw)
        try revealForManualControl()
    }

    private func revealForManualControl() throws {
        let moved = try session.revealAll { try Self.displayDestination(for: $0, owners: owners) }
        unhideIfNeeded()
        // Restoring a focused foreign window can drop activation. Complete this
        // handoff once; subsequent callbacks have no parked records to move.
        if moved { currentApp?.activate(options: [.activateAllWindows]) }
    }

    func userManuallyActivated(_: NSRunningApplication) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed else { return }
        try ensureTargetLease()
        try revealForManualControl()
    }

    func dispose() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed else { return }
        if !session.originalSpaces.isEmpty, !isCurrentAppActive, let app = currentApp {
            app.hide()
            try Self.waitFor("Messages hidden before restoration") {
                try Accessibility.Element(pid: app.processIdentifier).isHidden()
            }
        }
        try session.dispose()
        disposed = true
    }

    deinit {
        do { try dispose() } catch { log.error("Failed to restore unknown Space windows: \(error)") }
    }
}
