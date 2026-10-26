import Darwin
import Foundation
import IMessageCore
import IMessagePrivateSPI
import WindowControl

/// One WindowServer-owned parking Space per user, retained across host exits.
/// Discover by metadata, never by a numeric ID persisted across login sessions.
enum PersistentUnknownSpace {
    static let uuid = "Beeper-Unknown-Parking-v1-\(getuid())"
    private static let processLock = NSLock()
    private static let readTimeout: TimeInterval = 1
    private static let pollInterval: TimeInterval = 0.02

    struct Candidate {
        let id: UInt64
        let kind: Space.Kind
        let uuid: String?
        let hasManagedSpaceID: Bool
    }

    static func reusableID(in candidates: [Candidate]) -> UInt64? {
        candidates.filter {
            $0.id != 0 && $0.kind == .unknown && $0.uuid == uuid && !$0.hasManagedSpaceID
        }.map(\.id).min()
    }

    static func isReusable(_ id: UInt64) throws -> Bool {
        guard let value = try candidate(id) else { return false }
        return reusableID(in: [value]) == id
    }

    static func acquire(bridge: NSObject) throws -> UInt64 {
        processLock.lock()
        defer { processLock.unlock() }
        // The shared lock never unlinks its stable per-UID path. Keep its
        // descriptor alive through discovery, creation, and verified cleanup.
        let creationLock = try WindowCoordinationFileLock(name: "unknown-space-v1")
        defer { withExtendedLifetime(creationLock) {} }

        var candidates: [Candidate] = []
        for space in try Space.list(.allOSSpaces) {
            guard let id = UInt64(exactly: space.raw), id != 0 else { continue }
            if let value = try candidate(id) { candidates.append(value) }
        }
        if let existing = reusableID(in: candidates), try isReusable(existing) { return existing }

        let created = IMPrivateSPISpaceBridgeCreateUnknownSpace(bridge, uuid)
        guard created != 0 else { throw ErrorMessage("Bridge refused unknown Space creation") }
        do {
            let deadline = Date().addingTimeInterval(readTimeout)
            repeat {
                if try isReusable(created) { return created }
                guard try exists(created) else { throw ErrorMessage("The newly created unknown Space disappeared") }
                if Date() >= deadline { break }
                Thread.sleep(forTimeInterval: pollInterval)
            } while true
            throw ErrorMessage("Bridge did not create a recognizable unmanaged unknown Space")
        } catch {
            let kind = IMPrivateSPISpaceType(created)
            if kind >= 0 && kind != 3 {
                // A conclusively wrong kind can become a visible desktop. Do
                // not release the creation lock until its deletion is observed.
                try destroyMisclassifiedSpace(created, bridge: bridge)
            }
            // A type-3 Space with unreadable/incomplete metadata may be valid.
            // Retain it for a later discovery retry instead of enqueueing a
            // deletion another host could race with after taking this lock.
            throw error
        }
    }

    private static func candidate(_ id: UInt64) throws -> Candidate? {
        guard id != 0 else { return nil }
        let deadline = Date().addingTimeInterval(readTimeout)
        repeat {
            let kind = IMPrivateSPISpaceType(id)
            // Most system Spaces are unrelated; their metadata need not be
            // readable. Only genuinely unknown or inconclusive kinds need it.
            if kind >= 0 && kind != 3 { return nil }
            if kind == 3, let values = IMPrivateSPICopySpaceValues(id) {
                guard try exists(id) else { return nil }
                return Candidate(id: id, kind: .unknown,
                                 uuid: values["uuid"] as? String,
                                 hasManagedSpaceID: values["ManagedSpaceID"] != nil)
            }
            // Enumeration may race a Space disappearing. That is absence;
            // failure to read a still-live unknown Space is not.
            guard try exists(id) else { return nil }
            guard Date() < deadline else {
                throw ErrorMessage("Could not read metadata for live unknown Space \(id)")
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while true
    }

    private static func exists(_ id: UInt64) throws -> Bool {
        try Space.list(.allOSSpaces).contains { UInt64(exactly: $0.raw) == id }
    }

    private static func destroyMisclassifiedSpace(_ id: UInt64, bridge: NSObject) throws {
        // This ID came from our unshared creation attempt. A failed initial
        // enumeration must not prevent cleanup of a conclusively wrong kind.
        let active = IMPrivateSPIActiveSpace()
        guard active != 0, active != id else {
            throw ErrorMessage("Refusing to destroy an active or unverifiable misclassified Space")
        }
        if !IMPrivateSPISpaceBridgeDestroySpace(bridge, id) {
            if (try? exists(id)) == false { return }
            throw ErrorMessage("Bridge refused misclassified Space cleanup")
        }
        let deadline = Date().addingTimeInterval(3)
        repeat {
            // A transient enumeration failure must not release the lock while
            // the asynchronous destroy operation is still in flight.
            if (try? exists(id)) == false { return }
            guard Date() < deadline else {
                throw ErrorMessage("Timed out verifying misclassified Space cleanup")
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while true
    }
}
