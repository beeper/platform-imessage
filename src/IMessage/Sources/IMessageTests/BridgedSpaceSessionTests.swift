import Testing
import IMessageCore
@testable import IMessage

@Test
func bridgedSpaceSessionRestoresOriginalMembership() throws {
    var membership: [UInt32: [UInt64]] = [10: [1], 11: [2]]
    var creates = 0
    let session = BridgedSpaceSession(backend: .init(
        create: { creates += 1; return 99 },
        move: {
            membership[$0] = [$1]
        },
        spaces: { membership[$0] ?? [] }
    ))
    try session.park(10)
    try session.park(10)
    try session.park(11)
    #expect(creates == 1)
    #expect(membership[10] == [99])
    try session.restore(10)
    #expect(membership[10] == [1])
    try session.dispose()
    #expect(membership[11] == [2])
    #expect(session.hiddenSpace == nil)
    #expect(session.originalSpaces.isEmpty)
    try session.dispose()
}

@Test
func bridgedSpaceSessionPreservesRecoveryAfterUnverifiedMove() throws {
    var membership: [UInt64] = [1]
    var fail = true
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in
            membership = [space]
            if fail { throw ErrorMessage("Readback failed after applying move") }
        },
        spaces: { _ in membership }
    ))
    #expect(throws: (any Error).self) { try session.park(10) }
    #expect(session.originalSpaces[10] == 1)
    #expect(throws: (any Error).self) { try session.dispose() }
    #expect(session.originalSpaces[10] == 1)
    #expect(session.hiddenSpace == 99)
    fail = false
    try session.dispose()
    #expect(membership == [1])
}

@Test
func bridgedSpaceSessionRejectsAmbiguousOriginalSpaces() throws {
    var moved = false
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, _ in moved = true },
        spaces: { _ in [1, 2] }
    ))
    #expect(throws: (any Error).self) { try session.park(10) }
    #expect(!moved)
    #expect(session.originalSpaces.isEmpty)
    try session.dispose()
}

@Test
func bridgedSpaceSessionRestoresInitiallyUnassignedWindowToLaunchDesktop() throws {
    var membership: [UInt64] = []
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in membership = [space] },
        spaces: { _ in membership }
    ))
    try session.park(10, originalSpaceIfUnassigned: 1)
    #expect(membership == [99])
    try session.dispose()
    #expect(membership == [1])
}

@Test
func bridgedSpaceSessionCleansUpAfterWindowCloses() throws {
    var exists = true
    var moves = 0
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, _ in moves += 1 },
        spaces: { _ in [1] },
        exists: { _ in exists }
    ))
    try session.park(10)
    exists = false
    try session.dispose()
    #expect(moves == 1)
    #expect(session.originalSpaces.isEmpty)
}

@Test
func bridgedSpaceSessionRevealsOnCurrentDesktopAndReparksFromThere() throws {
    var membership: [UInt64] = [1]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in membership = [space] },
        spaces: { _ in membership }
    ))
    try session.park(10)
    // The user has moved to desktop 2 since automation began on desktop 1.
    try session.restore(10, to: 2)
    #expect(membership == [2])
    #expect(session.originalSpaces.isEmpty)
    try session.park(10)
    try session.dispose()
    #expect(membership == [2])
}

@Test(arguments: [UInt64(0), UInt64(99)])
func bridgedSpaceSessionRejectsInvalidRevealDestination(destination: UInt64) throws {
    var membership: [UInt64] = [1]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in membership = [space] },
        spaces: { _ in membership }
    ))
    try session.park(10)
    #expect(throws: (any Error).self) { try session.restore(10, to: destination) }
    #expect(membership == [99])
    #expect(session.originalSpaces[10] == 1)
    try session.dispose()
    #expect(membership == [1])
}

@Test
func bridgedSpaceSessionReacquiresDeletedParkingSpace() throws {
    var membership: [UInt64] = [1]
    var liveSpaces: Set<UInt64> = [1, 2]
    var creations: UInt64 = 98
    let session = BridgedSpaceSession(backend: .init(
        create: { creations += 1; liveSpaces.insert(creations); return creations },
        move: { _, space in
            guard liveSpaces.contains(space) else { throw ErrorMessage("Missing Space") }
            membership = [space]
        },
        spaces: { _ in membership },
        spaceExists: { liveSpaces.contains($0) }
    ))
    try session.park(10)
    #expect(membership == [99])
    liveSpaces.remove(99)
    membership = [2] // WindowServer relocates the window when its Space disappears.
    try session.park(10)
    #expect(membership == [100])
    #expect(session.hiddenSpace == 100)
    try session.dispose()
    #expect(membership == [1])
    #expect(liveSpaces == [1, 2, 100])
}

@Test
func bridgedSpaceSessionRecoversWhenOriginalDisplaySpacesDisappear() throws {
    var membership: [UInt64] = [1]
    var liveSpaces: Set<UInt64> = [1, 2, 99]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in membership = [space] },
        spaces: { _ in membership },
        spaceExists: { liveSpaces.contains($0) },
        fallbackSpace: { _ in 2 }
    ))
    try session.park(10)
    liveSpaces.remove(1)
    liveSpaces.remove(99)
    membership = [2]
    try session.dispose()
    #expect(membership == [2])
    #expect(session.hiddenSpace == nil)
    #expect(session.originalSpaces.isEmpty)
}

@Test
func bridgedSpaceSessionRestoresIdleWindowsWithoutDestroyingSpace() throws {
    var membership: [UInt32: [UInt64]] = [10: [1], 11: [2]]
    var closed = false
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { membership[$0] = [$1] },
        spaces: { membership[$0] ?? [] },
        exists: { !closed || $0 != 10 }
    ))
    try session.park(10)
    try session.park(11)
    closed = true
    try session.restoreAll()
    #expect(membership[11] == [2])
    #expect(session.originalSpaces.isEmpty)
    #expect(session.hiddenSpace == 99)
    // The next automation can reuse the parking Space, preserving the normal
    // desktop as the restoration destination.
    try session.park(11)
    #expect(membership[11] == [99])
    try session.restoreAll()
    #expect(membership[11] == [2])
}

@Test
func bridgedSpaceSessionInterruptedAutomationRevealsOnCurrentDesktop() throws {
    var membership: [UInt64] = [1]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in membership = [space] },
        spaces: { _ in membership }
    ))
    try session.park(10)
    let moved = try session.revealAll { _ in 2 }
    #expect(moved)
    #expect(membership == [2])
    #expect(session.originalSpaces.isEmpty)
    // Completion must not undo the user's choice of desktop.
    try session.restoreAll()
    #expect(membership == [2])
}

@Test
func bridgedSpaceSessionRejectsRevealingOnParkingSpace() throws {
    var membership: [UInt64] = [1]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in membership = [space] },
        spaces: { _ in membership }
    ))
    try session.park(10)
    #expect(throws: (any Error).self) { try session.revealAll { _ in 99 } }
    // The parking Space is never a valid foreground restoration destination.
    #expect(membership == [99])
    #expect(session.originalSpaces[10] == 1)
    try session.restoreAll()
    #expect(membership == [1])
}

@Test
func bridgedSpaceSessionRevealSkipsClosedWindowDestinationLookup() throws {
    var exists = true
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, _ in },
        spaces: { _ in [1] },
        exists: { _ in exists }
    ))
    try session.park(10)
    exists = false
    try session.revealAll { _ in
        Issue.record("Closed windows must be pruned before destination lookup")
        return 2
    }
    #expect(session.originalSpaces.isEmpty)
}

@Test
func bridgedSpaceSessionAdoptsWindowParkedByPreviousHost() throws {
    var membership: [UInt64] = [99]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in membership = [space] },
        spaces: { _ in membership }
    ))
    try session.park(10, originalSpaceIfUnassigned: 2)
    #expect(session.originalSpaces[10] == 2)
    #expect(membership == [99])
    try session.revealAll { _ in 3 }
    #expect(membership == [3])
    #expect(session.originalSpaces.isEmpty)
    try session.dispose()
    #expect(membership == [3])
}

@Test
func bridgedSpaceSessionDoesNotGuessRecoveryDesktopForAdoptedWindow() throws {
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 }, move: { _, _ in }, spaces: { _ in [99] }
    ))
    #expect(throws: (any Error).self) { try session.park(10) }
    #expect(session.originalSpaces.isEmpty)
}

@Test
func bridgedSpaceSessionAdoptsDuplicatePoolMembership() throws {
    var membership: [UInt64] = [100]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 }, move: { _, space in membership = [space] },
        spaces: { _ in membership },
        isOwnedParkingSpace: { $0 == 100 }
    ))
    try session.park(10, originalSpaceIfUnassigned: 2)
    #expect(membership == [99])
    #expect(session.originalSpaces[10] == 2)
    try session.dispose()
    #expect(membership == [2])
}
