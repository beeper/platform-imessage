import Foundation
@testable import IMessage
import Testing

@Suite(.serialized)
struct EventWatcherLifecycleTests {
    @Test func cancelWatchingCancelsStuckWatcherWithoutWaiting() async {
        let lifecycle = EventWatcherLifecycle.shared
        lifecycle.cancelWatchingIfNecessary(clearEventCallback: true)

        let gate = ContinuationGate()
        let stuckTask = Task {
            await gate.wait()
        }

        #expect(await eventually { await gate.isWaiting })

        lifecycle.setWatchingTaskForTesting(stuckTask)

        lifecycle.cancelWatchingIfNecessary(clearEventCallback: true)

        #expect(stuckTask.isCancelled)
        #expect(!lifecycle.isWatching)

        await gate.open()
        await stuckTask.value
    }
}

private actor ContinuationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private func eventually(timeout: TimeInterval = 1, _ predicate: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await predicate()
}
