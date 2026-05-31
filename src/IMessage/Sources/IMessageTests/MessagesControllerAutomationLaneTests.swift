import Foundation
@testable import IMessage
@testable import IMessageCore
import Testing

// Replaces the deleted PassivelyAwareDispatchQueueTests: the idle/serialization
// state machine was re-implemented in `MessagesControllerAutomationLane`, so the
// behavior still needs coverage. Adds tests for the actor-specific paths the old
// dispatch-queue version never had (serialization guarantee, cancellation,
// error isolation).

private struct Boom: Error {}

@Test func laneSerializesConcurrentWork() async throws {
    // idleDelay is irrelevant here; keep it long so idle work doesn't interfere.
    let lane = MessagesControllerAutomationLane(idleDelay: 10)
    let state = Protected<(active: Int, maxActive: Int)>((0, 0))

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<50 {
            group.addTask {
                try? await lane.run {
                    state.withLock { s in
                        s.active += 1
                        s.maxActive = max(s.maxActive, s.active)
                    }
                    // a window during which a second action would overlap if the
                    // lane weren't serial
                    try await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    state.withLock { $0.active -= 1 }
                }
            }
        }
    }

    #expect(state.read().maxActive == 1)
    #expect(state.read().active == 0)
}

@Test func laneRunsSequentialWorkInOrder() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 10)
    let order = Protected<[Int]>([])

    for i in 0..<10 {
        try await lane.run { order.withLock { $0.append(i) } }
    }

    #expect(order.read() == Array(0..<10))
}

@Test func laneIdleFiresAfterWorkDrains() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 0.02)
    let idleCount = Protected<Int>(0)
    await lane.setIdleCallback { idleCount.withLock { $0 += 1 } }

    try await lane.run {}

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { idleCount.read() >= 1 })
}

@Test func laneIdleRepeatsWhileQuiet() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 0.02)
    let idleCount = Protected<Int>(0)
    await lane.setIdleCallback { idleCount.withLock { $0 += 1 } }

    try await lane.run {}

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { idleCount.read() >= 2 })
}

@Test func laneIdleDoesNotFireWhileWorkInFlight() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 0.02)
    let idleFiredDuringWork = Protected<Bool>(false)
    let workRunning = Protected<Bool>(false)
    await lane.setIdleCallback {
        if workRunning.read() { idleFiredDuringWork.withLock { $0 = true } }
    }

    // work runs far longer than idleDelay; the idle callback must not interleave
    try await lane.run {
        workRunning.withLock { $0 = true }
        try await Task.sleep(nanoseconds: 80_000_000) // 80ms >> 20ms idleDelay
        workRunning.withLock { $0 = false }
    }

    #expect(idleFiredDuringWork.read() == false)
}

@Test func laneClearingIdleCallbackStopsFurtherIdleWork() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 0.02)
    let idleCount = Protected<Int>(0)
    await lane.setIdleCallback { idleCount.withLock { $0 += 1 } }

    try await lane.run {}
    _ = await eventually(timeout: 2, pollInterval: 0.005) { idleCount.read() >= 1 }

    await lane.setIdleCallback(nil)
    let countAtClear = idleCount.read()

    // several idle periods elapse; nothing more should fire
    try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
    #expect(idleCount.read() == countAtClear)
}

@Test func laneCancellingOneActionStillRunsOthers() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 10)
    let firstStarted = Protected<Bool>(false)
    let secondRan = Protected<Bool>(false)

    let first = Task {
        try await lane.run {
            firstStarted.withLock { $0 = true }
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5s; should be cancelled
        }
    }

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { firstStarted.read() })
    first.cancel()

    // a queued action behind the cancelled one must still execute
    try await lane.run { secondRan.withLock { $0 = true } }
    #expect(secondRan.read())

    // the cancelled action surfaces an error to its caller
    let firstResult = await first.result
    if case .success = firstResult {
        Issue.record("expected the cancelled action to throw")
    }
}

@Test func laneErrorInOneActionDoesNotBreakChain() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 10)

    await #expect(throws: Boom.self) {
        try await lane.run { throw Boom() }
    }

    let ran = Protected<Bool>(false)
    try await lane.run { ran.withLock { $0 = true } }
    #expect(ran.read())
}

@Test func laneRunReturnsActionValue() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 10)
    let value = try await lane.run { 42 }
    #expect(value == 42)
}
