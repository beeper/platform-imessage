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

@Test func threadHasherTokenizesThreadIDs() throws {
    let threadID = "any;-;fixture-contact-a@example.invalid"
    let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: threadID)

    #expect(hashedThreadID.hasPrefix("imsg##thread:"))
    #expect(hashedThreadID != threadID)
    #expect(try Hasher.thread.recoverOriginal(fromToken: hashedThreadID) == threadID)
}

@Test func hashingCanBeDisabled() throws {
    let hasher = Hasher(kind: "test")
    let token = hasher.tokenizeRemembering(pii: "foo", hashingEnabled: false)

    #expect(token == "foo")
    #expect(hasher.cache.isEmpty)
    #expect(hasher.originals.isEmpty)
}

@Test func forcedHashingStillSupportsRecoveryWhenHashingIsDisabled() throws {
    let hasher = Hasher(kind: "test")
    let token = hasher.tokenizeHashRemembering(pii: "foo")

    #expect(token.hasPrefix("imsg##test:"))
    #expect(try hasher.recoverOriginal(fromToken: token) == "foo")
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
