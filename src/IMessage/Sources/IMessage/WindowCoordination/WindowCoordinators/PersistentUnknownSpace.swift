import Darwin
import Foundation
import IMessageCore
import WindowControl

struct ParkingSpaceUnavailable: Error, CustomStringConvertible {
    let description: String
}

/// One WindowServer-owned parking Space per user, retained across host exits.
/// Discover by metadata, never by a numeric ID persisted across login sessions.
enum PersistentUnknownSpace {
    static let uuid = "Beeper-Unknown-Parking-v1-\(getuid())"
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
        guard let value = try Space(raw: id).flatMap(candidate) else { return false }
        return reusableID(in: [value]) == id
    }

    static func acquire() throws -> UInt64 {
        // The shared lock never unlinks its stable per-UID path. Keep its
        // descriptor alive through discovery, creation, and verified cleanup.
        let creationLock = try WindowCoordinationFileLock(name: "unknown-space-v1")
        defer { withExtendedLifetime(creationLock) {} }

        var candidates: [Candidate] = []
        for space in try Space.list(.allOSSpaces) {
            if let value = try candidate(space) { candidates.append(value) }
        }
        if let existing = reusableID(in: candidates), try isReusable(existing) { return existing }

        let created: Space
        do {
            created = try Space.createUnknown(uuid: uuid)
        } catch {
            throw ParkingSpaceUnavailable(description: "\(error)")
        }
        do {
            let deadline = Date().addingTimeInterval(readTimeout)
            repeat {
                if try isReusable(created.raw) { return created.raw }
                guard try Space.exists(created.raw) else { throw ErrorMessage("The newly created unknown Space disappeared") }
                if Date() >= deadline { break }
                Thread.sleep(forTimeInterval: pollInterval)
            } while true
            throw ErrorMessage("Bridge did not create a recognizable unmanaged unknown Space")
        } catch {
            if created.kind() != .unknown {
                // A conclusively wrong kind can become a visible desktop. Do
                // not release the creation lock until its deletion is observed.
                try destroyMisclassifiedSpace(created)
            }
            // A type-3 Space with unreadable/incomplete metadata may be valid.
            // Retain it for a later discovery retry instead of enqueueing a
            // deletion another host could race with after taking this lock.
            throw error
        }
    }

    private static func candidate(_ space: Space) throws -> Candidate? {
        let deadline = Date().addingTimeInterval(readTimeout)
        repeat {
            // Most system Spaces are unrelated; their metadata need not be
            // readable. WindowServer also reports vanished IDs as unknown,
            // so only an unknown kind needs metadata and an existence check.
            guard space.kind() == .unknown else { return nil }
            if let values = try? space.values() {
                guard try Space.exists(space.raw) else { return nil }
                return Candidate(id: space.raw, kind: .unknown,
                                 uuid: values["uuid"] as? String,
                                 hasManagedSpaceID: values["ManagedSpaceID"] != nil)
            }
            // Enumeration may race a Space disappearing. That is absence;
            // failure to read a still-live unknown Space is not.
            guard try Space.exists(space.raw) else { return nil }
            guard Date() < deadline else {
                throw ErrorMessage("Could not read metadata for live unknown Space \(space.raw)")
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while true
    }

    private static func destroyMisclassifiedSpace(_ space: Space) throws {
        // This ID came from our unshared creation attempt. A failed initial
        // enumeration must not prevent cleanup of a conclusively wrong kind.
        guard let active = try? Space.active(), active != space else {
            throw ErrorMessage("Refusing to destroy an active or unverifiable misclassified Space")
        }
        do {
            try space.destroy()
        } catch {
            if (try? Space.exists(space.raw)) == false { return }
            throw ErrorMessage("Bridge refused misclassified Space cleanup: \(error)")
        }
        let deadline = Date().addingTimeInterval(3)
        repeat {
            // A transient enumeration failure must not release the lock while
            // the asynchronous destroy operation is still in flight.
            if (try? Space.exists(space.raw)) == false { return }
            guard Date() < deadline else {
                throw ErrorMessage("Timed out verifying misclassified Space cleanup")
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while true
    }
}
