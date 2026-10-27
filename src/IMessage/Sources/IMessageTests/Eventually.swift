import Foundation
@testable import IMessage

func eventually(
    timeout: TimeInterval = 1,
    pollInterval: TimeInterval = 0.01,
    _ predicate: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if await predicate() {
            return true
        }
        try? await Task.sleep(forTimeInterval: max(0, pollInterval))
    }
    return await predicate()
}
