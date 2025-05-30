import CryptoKit
import Foundation
import SwiftServerFoundation

let maxDigestLength = 24

public final class Hasher {
    public typealias PII = String
    public typealias Token = String

    private let kind: String

    // TODO(skip): guard the data itself
    var lock = UnfairLock()
    // TODO(skip): not using `NSCache` because of potential bridging costs, but
    // this should use purgable memory
    var cache = [PII: Token]()
    var originals = [[UInt8]: PII]()

    public init(kind: String) {
        self.kind = kind
    }
}

// lock is used
extension Hasher: @unchecked Sendable {}

// MARK: - Public Interface

public extension Hasher {
    func recoverOriginal(fromToken token: Token) throws -> PII {
        lock.lock()
        defer { lock.unlock() }

        let hexString = token.drop(while: { $0 != ":" }).dropFirst()
        guard let original = originals[[UInt8](hexString: hexString)] else {
            throw ErrorMessage("couldn't recover original chat id for \(token)")
        }
        return original
    }

    func tokenizeRemembering(pii: PII) -> Token {
        lock.lock()
        defer { lock.unlock() }

        if let hit = cache[pii] {
            return hit
        }

        var sha = SHA512()
        sha.update(data: Data(assembleTextToHash(pii: pii).utf8))
        let digest = sha.finalize()

        let trimmedDigest = Array(digest.prefix(maxDigestLength))
        originals[trimmedDigest] = pii

        let token = assembleToken(hexedDigest: trimmedDigest.hexString())
        defer { cache[pii] = token }

        return token
    }
}

// MARK: - Implementation

private extension Hasher {
    private func assembleTextToHash(pii: PII) -> String {
        "\(kind)_50884d99c97714e59ad1a8147a145b5ef5528e40cba846de595af3f043327904_\(pii)"
    }

    private func assembleToken(hexedDigest: some StringProtocol) -> String {
        "imsg##\(kind):\(hexedDigest)"
    }
}
