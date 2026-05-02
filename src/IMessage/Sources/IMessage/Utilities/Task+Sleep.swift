import Foundation

extension Task where Success == Never, Failure == Never {
    static func sleep(forTimeInterval interval: TimeInterval) async throws {
        try await sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}
