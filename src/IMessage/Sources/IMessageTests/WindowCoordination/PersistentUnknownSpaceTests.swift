import Foundation
import Darwin
import IMessagePrivateSPI
import Testing
import WindowControl
@testable import IMessage

@Test
func persistentUnknownSpaceOnlyAdoptsValidatedOwnSpace() {
    typealias Candidate = PersistentUnknownSpace.Candidate
    let uuid = PersistentUnknownSpace.uuid
    let invalid: [Candidate] = [
        .init(id: 0, kind: .unknown, uuid: uuid, hasManagedSpaceID: false),
        .init(id: 1, kind: .user, uuid: uuid, hasManagedSpaceID: false),
        .init(id: 2, kind: .unknown, uuid: uuid, hasManagedSpaceID: true),
        .init(id: 3, kind: .unknown, uuid: "Beeper-Unknown-Research-other", hasManagedSpaceID: false),
        .init(id: 4, kind: .unknown, uuid: nil, hasManagedSpaceID: false),
        .init(id: 5, kind: .unknown, uuid: uuid + "-another-user", hasManagedSpaceID: false),
    ]
    #expect(PersistentUnknownSpace.reusableID(in: invalid) == nil)
    let own = Candidate(id: 99, kind: .unknown, uuid: uuid, hasManagedSpaceID: false)
    #expect(PersistentUnknownSpace.reusableID(in: invalid + [own]) == 99)
}

@Test
func persistentUnknownSpaceChoosesSameCandidateRegardlessOfEnumerationOrder() {
    let uuid = PersistentUnknownSpace.uuid
    let first = PersistentUnknownSpace.Candidate(id: 99, kind: .unknown, uuid: uuid, hasManagedSpaceID: false)
    let duplicate = PersistentUnknownSpace.Candidate(id: 100, kind: .unknown, uuid: uuid, hasManagedSpaceID: false)
    #expect(PersistentUnknownSpace.reusableID(in: [first, duplicate]) == 99)
    #expect(PersistentUnknownSpace.reusableID(in: [duplicate, first]) == 99)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_UNKNOWN_SPACE_POOL_SMOKE"] == "1"))
func persistentUnknownSpaceLiveReuseSmoke() throws {
    let managedBefore = try #require(IMPrivateSPICopyManagedDisplaySpaces()) as NSArray
    var selected: UInt64?
    for _ in 0..<12 {
        let bridge = try #require(IMPrivateSPISpaceBridgeCreate())
        let acquired = try PersistentUnknownSpace.acquire(bridge: bridge)
        if let selected { #expect(acquired == selected) }
        selected = acquired
        #expect(try PersistentUnknownSpace.isReusable(acquired))
    }
    #expect(try #require(IMPrivateSPICopyManagedDisplaySpaces()) as NSArray == managedBefore)
    print("UNKNOWN_SPACE_POOL_REUSE launcherPID=\(getpid()) space=\(try #require(selected)) acquisitions=12")
    fflush(nil)
}
