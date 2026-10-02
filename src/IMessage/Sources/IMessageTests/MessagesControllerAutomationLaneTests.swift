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
    let lane = MessagesControllerAutomationLane(idleDelay: 0.1)
    let idleCount = Protected<Int>(0)
    await lane.setIdleCallback { idleCount.withLock { $0 += 1 } }

    try await lane.run {}

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { idleCount.read() >= 1 })
}

@Test func laneIdleRepeatsWhileQuiet() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 0.1)
    let idleCount = Protected<Int>(0)
    await lane.setIdleCallback { idleCount.withLock { $0 += 1 } }

    try await lane.run {}

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { idleCount.read() >= 2 })
}

@Test func laneStaleIdleIsSuppressedByNewWorkEpochBump() async throws {
    // Exercises the epoch guard (`idleCallbackIfStillCurrent`) and `activeWorkSubmitted`'s
    // epoch bump: new work submitted before idleDelay elapses must cancel the stale idle.
    let idleDelay: TimeInterval = 0.1
    let lane = MessagesControllerAutomationLane(idleDelay: idleDelay)

    // Record the time of each idle fire so we can reason about which cycle fired.
    let idleFires = Protected<[Date]>([])
    await lane.setIdleCallback { idleFires.withLock { $0.append(Date()) } }

    // (1) First drain schedules an idle for epoch E.
    try await lane.run {}
    let afterFirstDrain = Date()

    // (2) Submit + (3) drain new work well before idleDelay elapses. This bumps the
    // epoch and cancels the stale epoch-E idle before it can fire.
    try await Task.sleep(nanoseconds: UInt64(idleDelay * 0.3 * 1_000_000_000))
    try await lane.run {}
    let afterSecondDrain = Date()

    // No idle should have fired yet: the stale epoch-E idle was suppressed, and the
    // fresh idle hasn't waited out idleDelay.
    #expect(idleFires.read().isEmpty)

    // (4) Wait out the fresh idle and confirm it fires.
    #expect(await eventually(timeout: 2, pollInterval: 0.005) { idleFires.read().count >= 1 })

    // The fire that occurred must belong to the fresh (post-second-drain) cycle: it
    // happens at least idleDelay after the second drain. A surviving stale epoch-E idle
    // would have fired ~idleDelay after the FIRST drain, i.e. before this point.
    let firstFire = idleFires.read().first!
    #expect(firstFire.timeIntervalSince(afterSecondDrain) >= idleDelay * 0.5)
    // Sanity: the stale idle (epoch E) would have been due ~idleDelay after the first
    // drain; that moment has passed without a fire attributable to it.
    #expect(firstFire.timeIntervalSince(afterFirstDrain) >= idleDelay)
}

@Test func laneClearingIdleCallbackStopsFurtherIdleWork() async throws {
    let idleDelay: TimeInterval = 0.1
    let lane = MessagesControllerAutomationLane(idleDelay: idleDelay)
    let idleCount = Protected<Int>(0)
    await lane.setIdleCallback { idleCount.withLock { $0 += 1 } }

    try await lane.run {}

    // Wait for at least 3 idle cycles to confirm the repeating idle is healthy.
    #expect(await eventually(timeout: 2, pollInterval: 0.005) { idleCount.read() >= 3 })

    await lane.setIdleCallback(nil)
    let countAtClear = idleCount.read()

    // Several more idle periods elapse; with the callback cleared, nothing more fires.
    try? await Task.sleep(nanoseconds: UInt64(idleDelay * 4 * 1_000_000_000))
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

@Test func laneCancellingQueuedActionNeverRunsIt() async throws {
    // Distinct from laneCancellingOneActionStillRunsOthers (which cancels an action
    // that has already STARTED): here we cancel an action while it is still QUEUED
    // behind a long-running one. It must surface an error and never execute its body.
    let lane = MessagesControllerAutomationLane(idleDelay: 10)
    let firstStarted = Protected<Bool>(false)
    let releaseFirst = Protected<Bool>(false)
    let secondRan = Protected<Bool>(false)

    let first = Task {
        try await lane.run {
            firstStarted.withLock { $0 = true }
            while !releaseFirst.read() {
                try await Task.sleep(nanoseconds: 2_000_000) // 2ms
            }
        }
    }
    #expect(await eventually(timeout: 2, pollInterval: 0.005) { firstStarted.read() })

    // Queue the second action behind the (still-running) first, then cancel it.
    let second = Task {
        try await lane.run { secondRan.withLock { $0 = true } }
    }
    try await Task.sleep(nanoseconds: 20_000_000) // let it enqueue behind `first`
    second.cancel()

    // Drain the lane.
    releaseFirst.withLock { $0 = true }
    _ = try? await first.value

    let secondResult = await second.result
    #expect(throws: (any Error).self) { try secondResult.get() }

    // Give the lane a beat; the cancelled-while-queued body must not have run.
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(secondRan.read() == false)
}

@Test func laneIdleUsesLatestCallbackAfterMidFlightSwap() async throws {
    // Swapping the idle callback while an action is in flight must drop the old
    // callback entirely; only the latest one fires once work drains.
    let lane = MessagesControllerAutomationLane(idleDelay: 0.1)
    let firstCallbackFired = Protected<Bool>(false)
    let secondCallbackFired = Protected<Bool>(false)

    await lane.setIdleCallback { firstCallbackFired.withLock { $0 = true } }

    try await lane.run {
        await lane.setIdleCallback { secondCallbackFired.withLock { $0 = true } }
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms, still in flight
    }

    #expect(await eventually(timeout: 2, pollInterval: 0.005) { secondCallbackFired.read() })
    #expect(firstCallbackFired.read() == false)
}

@Test func laneAllowsEscapedChildToEnqueueAfterOriginatingActionFinishes() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 10)
    let releaseChild = Protected<Bool>(false)
    let childRanOnLane = Protected<Bool>(false)
    let escapedTask = Protected<Task<Void, Error>?>(nil)

    try await lane.run {
        let task = Task {
            while !releaseChild.read() {
                await Task.yield()
            }
            try await lane.run {
                childRanOnLane.withLock { $0 = true }
            }
        }
        escapedTask.withLock { $0 = task }
    }

    releaseChild.withLock { $0 = true }
    let task = try #require(escapedTask.read())
    try await task.value

    #expect(childRanOnLane.read())
}

@Test func laneExplicitEscapingTaskCanEnqueueIndependently() async throws {
    let lane = MessagesControllerAutomationLane(idleDelay: 10)
    let childStarted = Protected<Bool>(false)
    let childRanOnLane = Protected<Bool>(false)
    let escapedTask = Protected<Task<Void, Error>?>(nil)

    try await lane.run {
        let task = MessagesControllerAutomationLane.escapingTask {
            childStarted.withLock { $0 = true }
            try await lane.run {
                childRanOnLane.withLock { $0 = true }
            }
        }
        escapedTask.withLock { $0 = task }

        #expect(await eventually(timeout: 2, pollInterval: 0.005) { childStarted.read() })
        // Keep the originating action alive long enough for the child to enter
        // `run`; the child must enqueue rather than inherit a matching lane token.
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    let task = try #require(escapedTask.read())
    try await task.value
    #expect(childRanOnLane.read())
}

// NOTE: lane re-entrancy (calling `run` from within a `run` action) is guarded by a
// `precondition` in `MessagesControllerAutomationLane.run`. Asserting that it traps
// would require a Swift Testing exit test (subprocess + signal matching), which is
// fragile and toolchain-version-sensitive, so it is intentionally not unit-tested
// here. The contract is enforced by comparing `executionToken` with the actor's
// `activeExecutionToken`.
