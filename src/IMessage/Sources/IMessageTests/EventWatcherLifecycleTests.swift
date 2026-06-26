import Foundation
@testable import IMessage
import Testing

@Suite(.serialized)
struct EventWatcherLifecycleTests {
    @Test func cancelWatchingCanSkipWaitingForStuckWatcher() async {
        let lifecycle = EventWatcherLifecycle.shared
        await lifecycle.cancelWatchingIfNecessary(clearEventCallback: true, shutdownGracePeriod: 0.001)

        let gate = ContinuationGate()
        let stuckTask = Task {
            await gate.wait()
        }

        #expect(await eventually { await gate.isWaiting })

        lifecycle.setWatchingTaskForTesting(stuckTask)

        let start = Date()
        await lifecycle.cancelWatchingIfNecessary(clearEventCallback: true, shutdownGracePeriod: nil)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.05)
        #expect(stuckTask.isCancelled)
        #expect(!lifecycle.isWatching)

        await gate.open()
        await stuckTask.value
    }

    @Test func cancelWatchingTimesOutWhenWatcherDoesNotFinish() async {
        let lifecycle = EventWatcherLifecycle.shared
        await lifecycle.cancelWatchingIfNecessary(clearEventCallback: true, shutdownGracePeriod: 0.001)

        let gate = ContinuationGate()
        let stuckTask = Task {
            await gate.wait()
        }

        #expect(await eventually { await gate.isWaiting })

        lifecycle.setWatchingTaskForTesting(stuckTask)

        let start = Date()
        await lifecycle.cancelWatchingIfNecessary(clearEventCallback: true, shutdownGracePeriod: 0.05)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= 0.05)
        #expect(elapsed < 0.5)
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
