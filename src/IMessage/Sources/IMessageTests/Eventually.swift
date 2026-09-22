import Foundation

func eventually(
    timeout: TimeInterval = 1,
    pollInterval: TimeInterval = 0.01,
    _ predicate: @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let pollNanoseconds = UInt64(max(0, pollInterval) * 1_000_000_000)

    while Date() < deadline {
        if predicate() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return predicate()
}
