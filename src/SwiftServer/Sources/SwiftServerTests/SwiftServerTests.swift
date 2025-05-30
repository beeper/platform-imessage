import Foundation
@testable import SwiftServer
import Testing

@Test func hashing() {
    let hasher = Hasher(kind: "test")

    let token = hasher.tokenizeRemembering(pii: "foo")
    #expect(try hasher.recoverOriginal(fromToken: token) == "foo")

    #expect(try hasher.recoverOriginal(fromToken: "!" + token) == "foo")

    #expect(hasher.cache.count == 1)
    #expect(hasher.originals.count == 1)
}

@Test func hashingThreadsafe() async {
    let hasher = Hasher(kind: "test")

    let groups = 10
    let tokenizationsPerGroup = 10000

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
