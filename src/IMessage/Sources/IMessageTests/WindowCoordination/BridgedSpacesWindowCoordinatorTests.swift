import Foundation
import Testing
import IMessageCore
@testable import IMessage

@Test
func bridgedCoordinatorReleasesLeaseAfterRestorationWhileRetained() throws {
    let name = "test-coordinator-dispose-\(UUID().uuidString)"
    var membership: [UInt64] = [1]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in
            if space == 1 {
                // Ownership must remain exclusive until restoration completes.
                try expectLeaseUnavailable(name)
            }
            membership = [space]
        },
        spaces: { _ in membership }
    ))
    try session.park(10)
    let coordinator = BridgedSpacesWindowCoordinator(
        session: session,
        targetLease: try WindowCoordinationFileLock(name: name, wait: false)
    )
    try withExtendedLifetime(coordinator) {
        try coordinator.dispose()
        #expect(membership == [1])
        let next = try WindowCoordinationFileLock(name: name, wait: false)
        try withExtendedLifetime(next) {
            // Repeated disposal must not affect the next owner's lease.
            try coordinator.dispose()
            try expectLeaseUnavailable(name)
        }
    }
}

@Test
func bridgedCoordinatorKeepsLeaseWhenRestorationFails() throws {
    let name = "test-coordinator-failed-dispose-\(UUID().uuidString)"
    var membership: [UInt64] = [1]
    var failRestoration = true
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in
            if space == 1, failRestoration { throw ErrorMessage("Restoration failed") }
            membership = [space]
        },
        spaces: { _ in membership }
    ))
    try session.park(10)
    let coordinator = BridgedSpacesWindowCoordinator(
        session: session,
        targetLease: try WindowCoordinationFileLock(name: name, wait: false)
    )
    try withExtendedLifetime(coordinator) {
        #expect(throws: (any Error).self) { try coordinator.dispose() }
        try expectLeaseUnavailable(name)
        failRestoration = false
        try coordinator.dispose()
        let next = try WindowCoordinationFileLock(name: name, wait: false)
        withExtendedLifetime(next) {}
    }
}

private func expectLeaseUnavailable(_ name: String) throws {
    do {
        let unexpected = try WindowCoordinationFileLock(name: name, wait: false)
        _ = withExtendedLifetime(unexpected) { Issue.record("Ownership was released too early") }
    } catch WindowCoordinatorError.instanceInUse {
        // Other failures propagate instead of satisfying this assertion.
    }
}
