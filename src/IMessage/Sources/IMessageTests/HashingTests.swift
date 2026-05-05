import Foundation
@testable import IMessage
import Testing

@Test func hashing() throws {
    let hasher = Hasher(kind: "test")

    let token = hasher.tokenizeRemembering(pii: "foo")
    #expect(try hasher.recoverOriginal(fromToken: token) == "foo")

    #expect(try hasher.recoverOriginal(fromToken: "!" + token) == "foo")

    #expect(hasher.cache.count == 1)
    #expect(hasher.originals.count == 1)
}

@Test func platformAPIHashesThreadIDs() throws {
    let threadID = "any;-;sjobs@apple.com"
    let hashedThreadID = PlatformAPI.hashedThreadID(threadID)

    #expect(hashedThreadID.hasPrefix("imsg##thread:"))
    #expect(hashedThreadID != threadID)
    #expect(try Hasher.thread.recoverOriginal(fromToken: hashedThreadID) == threadID)
}

@Test func hashingThreadsafe() async {
    let hasher = Hasher(kind: "test")

    let groups = 10
    let tokenizationsPerGroup = 10_000

    await withTaskGroup { group in
        for _ in 0 ..< groups {
            group.addTask {
                for _ in 0 ..< tokenizationsPerGroup {
                    _ = hasher.tokenizeRemembering(pii: UUID().uuidString)
                }
            }
        }

        await group.waitForAll()
    }

    #expect(hasher.originals.count == groups * tokenizationsPerGroup)
}
