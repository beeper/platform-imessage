import Foundation
@testable import IMessage
@testable import IMessageCore
import Testing

private final class TestMessagesController {
    let id: Int
    let disposed = Protected(false)

    init(id: Int) { self.id = id }
}

@Test(arguments: [false, true])
func rejectedCallerCannotInvalidateACachedController(cancelCaller: Bool) async throws {
    let wasDisposed = Protected(false)
    let controller = UncheckedSendableBox(TestMessagesController(id: 1))
    let coordinator = MessagesControllerCoordinator<TestMessagesController>(
        create: { _ in controller },
        isValid: { _ in true },
        dispose: { _ in wasDisposed.withLock { $0 = true } }
    )
    _ = try await coordinator.withController(reportErrorMessage: nil, hasBeenDisposed: Protected(false)) { $0.id }
    let task = Task {
        if cancelCaller { withUnsafeCurrentTask { $0?.cancel() } }
        return try await coordinator.withController(
            reportErrorMessage: nil, hasBeenDisposed: Protected(!cancelCaller), forceInvalidate: true
        ) { $0.id }
    }
    let result = await task.result
    #expect(throws: (any Error).self) { try result.get() }
    #expect(!wasDisposed.read())
}

@Test func controllerReplacementWaitsForDisposalAndConcurrentDisposers() async throws {
    let creations = Protected(0)
    let disposalStarted = Protected(false)
    let secondDisposalReturned = Protected(false)
    let replacementReturned = Protected(false)
    let (releaseDisposal, disposalGate) = AsyncStream<Void>.makeStream()
    defer { disposalGate.finish() }
    let coordinator = MessagesControllerCoordinator<TestMessagesController>(
        create: { _ in
            let id = creations.withLock { $0 += 1; return $0 }
            return UncheckedSendableBox(TestMessagesController(id: id))
        },
        isValid: { !$0.disposed.read() },
        dispose: { entry in
            disposalStarted.withLock { $0 = true }
            for await _ in releaseDisposal {}
            entry.value.disposed.withLock { $0 = true }
        }
    )
    let disposed = Protected(false)
    let firstID = try await coordinator.withController(reportErrorMessage: nil, hasBeenDisposed: disposed) { $0.id }
    #expect(firstID == 1)

    let disposal = Task { try await coordinator.disposeCachedController() }
    #expect(await eventually { disposalStarted.read() })
    let secondDisposal = Task {
        try await coordinator.disposeCachedController()
        secondDisposalReturned.withLock { $0 = true }
    }
    let replacement = Task {
        let id = try await coordinator.withController(reportErrorMessage: nil, hasBeenDisposed: disposed) { $0.id }
        replacementReturned.withLock { $0 = true }
        return id
    }
    try await Task.sleep(forTimeInterval: 0.05)
    #expect(creations.read() == 1)
    #expect(!secondDisposalReturned.read())
    #expect(!replacementReturned.read())

    // Cancelling the invalidating caller must not cancel cleanup or release the barrier.
    disposal.cancel()
    disposalGate.finish()
    try await disposal.value
    try await secondDisposal.value
    #expect(try await replacement.value == 2)
}

@Test func invalidatedConstructionFinishesDisposalBeforeReplacementStarts() async throws {
    let creations = Protected(0)
    let constructionStarted = Protected(false)
    let disposalStarted = Protected(false)
    let (releaseConstruction, constructionGate) = AsyncStream<Void>.makeStream()
    let (releaseDisposal, disposalGate) = AsyncStream<Void>.makeStream()
    defer { constructionGate.finish(); disposalGate.finish() }
    let coordinator = MessagesControllerCoordinator<TestMessagesController>(
        create: { _ in
            let id = creations.withLock { $0 += 1; return $0 }
            if id == 1 {
                constructionStarted.withLock { $0 = true }
                for await _ in releaseConstruction {}
            }
            return UncheckedSendableBox(TestMessagesController(id: id))
        },
        isValid: { !$0.disposed.read() },
        dispose: { entry in
            disposalStarted.withLock { $0 = true }
            for await _ in releaseDisposal {}
            entry.value.disposed.withLock { $0 = true }
        }
    )
    let disposed = Protected(false)
    let first = Task {
        try await coordinator.withController(reportErrorMessage: nil, hasBeenDisposed: disposed) { $0.id }
    }
    #expect(await eventually { constructionStarted.read() })
    let invalidation = Task { try await coordinator.disposeCachedController() }
    // The replacement lookup also acts as an actor hop after submitting invalidation.
    try await Task.sleep(forTimeInterval: 0.05)
    let replacement = Task {
        try await coordinator.withController(reportErrorMessage: nil, hasBeenDisposed: disposed) { $0.id }
    }
    constructionGate.finish()
    #expect(await eventually { disposalStarted.read() })
    try await Task.sleep(forTimeInterval: 0.05)
    #expect(creations.read() == 1)
    disposalGate.finish()
    try await invalidation.value
    #expect(try await first.value == 2)
    #expect(try await replacement.value == 2)
    #expect(creations.read() == 2)
}

@Test func controllerConstructionIsSharedByConcurrentCallers() async throws {
    let creations = Protected(0)
    let coordinator = MessagesControllerCoordinator<TestMessagesController>(
        create: { _ in
            let id = creations.withLock { $0 += 1; return $0 }
            try await Task.sleep(forTimeInterval: 0.05)
            return UncheckedSendableBox(TestMessagesController(id: id))
        },
        isValid: { !$0.disposed.read() },
        dispose: { $0.value.disposed.withLock { $0 = true } }
    )
    let disposed = Protected(false)
    try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<20 {
            group.addTask {
                try await coordinator.withController(reportErrorMessage: nil, hasBeenDisposed: disposed) { $0.id }
            }
        }
        for try await id in group { #expect(id == 1) }
    }
    #expect(creations.read() == 1)
}
