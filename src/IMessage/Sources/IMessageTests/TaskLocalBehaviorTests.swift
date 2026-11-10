import Foundation
@testable import IMessageCore
import Testing

// These tests pin the Swift TaskLocal behaviors that
// MessagesControllerAutomationLane's re-entry detection relies on.
private enum TaskLocalTestContext {
    @TaskLocal static var laneToken: UUID?
    @TaskLocal static var unrelatedValue: String?
}

private actor TaskLocalProbe {
    func laneToken() -> UUID? {
        TaskLocalTestContext.laneToken
    }
}

@Test func taskLocalIsInheritedByUnstructuredTaskAfterScopeEnds() async {
    let expectedToken = UUID()
    let releaseChild = Protected<Bool>(false)

    let child = TaskLocalTestContext.$laneToken.withValue(expectedToken) {
        Task {
            while !releaseChild.read() {
                await Task.yield()
            }
            return TaskLocalTestContext.laneToken
        }
    }

    // Read only after `withValue` has restored the parent's prior value. The child
    // must retain the value it inherited when `Task {}` was created.
    releaseChild.withLock { $0 = true }

    #expect(await child.value == expectedToken)
    #expect(TaskLocalTestContext.laneToken == nil)
}

@Test func taskLocalPropagatesAcrossActorHop() async {
    let expectedToken = UUID()
    let probe = TaskLocalProbe()

    let observedToken = await TaskLocalTestContext.$laneToken.withValue(expectedToken) {
        await probe.laneToken()
    }

    #expect(observedToken == expectedToken)
}

@Test func taskLocalCanBeClearedWithoutDiscardingUnrelatedContext() async {
    let inheritedToken = UUID()

    let child = TaskLocalTestContext.$laneToken.withValue(inheritedToken) {
        TaskLocalTestContext.$unrelatedValue.withValue("preserved") {
            TaskLocalTestContext.$laneToken.withValue(nil) {
                Task {
                    (
                        laneToken: TaskLocalTestContext.laneToken,
                        unrelatedValue: TaskLocalTestContext.unrelatedValue
                    )
                }
            }
        }
    }

    let observed = await child.value
    #expect(observed.laneToken == nil)
    #expect(observed.unrelatedValue == "preserved")
}
