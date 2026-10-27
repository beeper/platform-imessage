import IMessageCore

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
