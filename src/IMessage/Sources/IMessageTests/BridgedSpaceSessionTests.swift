import Testing
import IMessageCore
@testable import IMessage

@Test
func bridgedSpaceSessionRestoresOriginalMembership() throws {
    var membership: [UInt32: [UInt64]] = [10: [1], 11: [2]]
    var destroyed: [UInt64] = []
    var creates = 0
    let session = BridgedSpaceSession(backend: .init(
        create: { creates += 1; return 99 },
        move: {
            membership[$0] = [$1]
        },
        spaces: { membership[$0] ?? [] },
        destroy: { destroyed.append($0) }
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
    #expect(destroyed == [99])
    try session.dispose()
    #expect(destroyed == [99])
}

@Test
func bridgedSpaceSessionPreservesRecoveryAfterUnverifiedMove() throws {
    var membership: [UInt64] = [1]
    var fail = true
    var destroyed = false
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in
            membership = [space]
            if fail { throw ErrorMessage("Readback failed after applying move") }
        },
        spaces: { _ in membership },
        destroy: { _ in destroyed = true }
    ))
    #expect(throws: (any Error).self) { try session.park(10) }
    #expect(session.originalSpaces[10] == 1)
    #expect(throws: (any Error).self) { try session.dispose() }
    #expect(!destroyed)
    fail = false
    try session.dispose()
    #expect(membership == [1])
    #expect(destroyed)
}

@Test
func bridgedSpaceSessionRejectsAmbiguousOriginalSpaces() throws {
    var moved = false
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, _ in moved = true },
        spaces: { _ in [1, 2] },
        destroy: { _ in }
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
        spaces: { _ in membership },
        destroy: { _ in }
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
    var destroyed = false
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, _ in moves += 1 },
        spaces: { _ in [1] },
        destroy: { _ in destroyed = true },
        exists: { _ in exists }
    ))
    try session.park(10)
    exists = false
    try session.dispose()
    #expect(moves == 1)
    #expect(destroyed)
    #expect(session.originalSpaces.isEmpty)
}

@Test
func bridgedSpaceSessionRevealsOnCurrentDesktopAndReparksFromThere() throws {
    var membership: [UInt64] = [1]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in membership = [space] },
        spaces: { _ in membership },
        destroy: { _ in }
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
        spaces: { _ in membership },
        destroy: { _ in }
    ))
    try session.park(10)
    #expect(throws: (any Error).self) { try session.restore(10, to: destination) }
    #expect(membership == [99])
    #expect(session.originalSpaces[10] == 1)
    try session.dispose()
    #expect(membership == [1])
}

@Test
func bridgedSpaceSessionRecreatesDeletedTemporarySpace() throws {
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
        destroy: { liveSpaces.remove($0) },
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
    #expect(liveSpaces == [1, 2])
}

@Test
func bridgedSpaceSessionRecoversWhenOriginalDisplaySpacesDisappear() throws {
    var membership: [UInt64] = [1]
    var liveSpaces: Set<UInt64> = [1, 2, 99]
    let session = BridgedSpaceSession(backend: .init(
        create: { 99 },
        move: { _, space in membership = [space] },
        spaces: { _ in membership },
        destroy: { liveSpaces.remove($0) },
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
