import Dispatch
import Foundation
import IMessageCore
import Testing

@Test func passivelyAwareQueueFiresIdleAfterActiveWorkDrains() {
    let queue = PassivelyAwareDispatchQueue(label: testQueueLabel(), idleDelay: 0.02)
    let observations = Protected<[String]>([])
    let idleObserved = DispatchSemaphore(value: 0)
    let workFinished = DispatchSemaphore(value: 0)

    queue.setIdleCallback { quiescence in
        observations.withLock { $0.append(label(for: quiescence)) }
        idleObserved.signal()
    }

    queue.async {
        workFinished.signal()
    }

    #expect(workFinished.wait(timeout: .now() + 1) == .success)
    #expect(idleObserved.wait(timeout: .now() + 1) == .success)
    #expect(observations.read().first == "began")
}

@Test func passivelyAwareQueueSuppressesStaleIdleCallbacksAfterNewWork() {
    let queue = PassivelyAwareDispatchQueue(label: testQueueLabel(), idleDelay: 0.3)
    let observations = Protected<[String]>([])
    let idleObserved = DispatchSemaphore(value: 0)
    let firstWorkFinished = DispatchSemaphore(value: 0)
    let secondWorkFinished = DispatchSemaphore(value: 0)

    queue.setIdleCallback { quiescence in
        observations.withLock { $0.append(label(for: quiescence)) }
        idleObserved.signal()
    }

    queue.async {
        firstWorkFinished.signal()
    }
    #expect(firstWorkFinished.wait(timeout: .now() + 1) == .success)

    Thread.sleep(forTimeInterval: 0.1)

    queue.async {
        secondWorkFinished.signal()
    }
    #expect(secondWorkFinished.wait(timeout: .now() + 1) == .success)

    #expect(idleObserved.wait(timeout: .now() + 0.25) == .timedOut)
    #expect(idleObserved.wait(timeout: .now() + 1) == .success)
    #expect(observations.read() == ["began"])
}

@Test func passivelyAwareQueueRepeatsContinuingIdleWhileQuiet() {
    let queue = PassivelyAwareDispatchQueue(label: testQueueLabel(), idleDelay: 0.02)
    let observations = Protected<[String]>([])
    let idleObservedTwice = DispatchSemaphore(value: 0)

    queue.setIdleCallback { quiescence in
        let count = observations.withLock { observations in
            observations.append(label(for: quiescence))
            return observations.count
        }
        if count == 2 {
            idleObservedTwice.signal()
        }
    }

    queue.async {}

    #expect(idleObservedTwice.wait(timeout: .now() + 1) == .success)
    #expect(Array(observations.read().prefix(2)) == ["began", "continuing"])
}

@Test func passivelyAwareQueueSuppressesContinuingIdleWhenIdleCallbackEnqueuesWork() {
    let queue = PassivelyAwareDispatchQueue(label: testQueueLabel(), idleDelay: 0.02)
    let observations = Protected<[String]>([])
    let didScheduleReentrantWork = Protected<Bool>(false)
    let initialWorkFinished = DispatchSemaphore(value: 0)
    let reentrantWorkFinished = DispatchSemaphore(value: 0)
    let idleObservedTwice = DispatchSemaphore(value: 0)

    queue.setIdleCallback { quiescence in
        let count = observations.withLock { observations in
            observations.append(label(for: quiescence))
            return observations.count
        }
        if !didScheduleReentrantWork.withLock({ scheduled in
            defer { scheduled = true }
            return scheduled
        }) {
            queue.async {
                reentrantWorkFinished.signal()
            }
        }
        if count == 2 {
            idleObservedTwice.signal()
        }
    }

    queue.async {
        initialWorkFinished.signal()
    }

    #expect(initialWorkFinished.wait(timeout: .now() + 1) == .success)
    #expect(reentrantWorkFinished.wait(timeout: .now() + 1) == .success)
    #expect(idleObservedTwice.wait(timeout: .now() + 1) == .success)
    #expect(Array(observations.read().prefix(2)) == ["began", "began"])
}

@Test func passivelyAwareQueueHandlesRapidConcurrentSubmissions() {
    let queue = PassivelyAwareDispatchQueue(label: testQueueLabel(), idleDelay: 0.01)
    let totalWorkItems = 500
    let completedCount = Protected<Int>(0)
    let allWorkFinished = DispatchSemaphore(value: 0)
    let idleObserved = DispatchSemaphore(value: 0)

    queue.setIdleCallback { quiescence in
        if case .began = quiescence {
            idleObserved.signal()
        }
    }

    DispatchQueue.concurrentPerform(iterations: totalWorkItems) { _ in
        queue.async {
            let completed = completedCount.withLock { count in
                count += 1
                return count
            }
            if completed == totalWorkItems {
                allWorkFinished.signal()
            }
        }
    }

    #expect(allWorkFinished.wait(timeout: .now() + 2) == .success)
    #expect(idleObserved.wait(timeout: .now() + 2) == .success)
    #expect(completedCount.read() == totalWorkItems)
}

private func label(for quiescence: Quiescence) -> String {
    switch quiescence {
    case .began:
        return "began"
    case .continuing:
        return "continuing"
    }
}

private func testQueueLabel() -> String {
    "passively-aware-dispatch-queue-test-\(UUID().uuidString)"
}
