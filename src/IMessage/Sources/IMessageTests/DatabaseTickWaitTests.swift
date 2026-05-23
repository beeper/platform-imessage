import Foundation
import IMDatabase
@testable import IMessage
import IMessageCore
import PlatformSDK
import Testing

@Test func topicRemovesTerminatedSubscriptions() async throws {
    let topic = Topic<Void>()
    let task = Task {
        for await _ in topic.subscribe() {}
    }

    #expect(await eventually { topic.subscriptionCount == 1 })
    task.cancel()
    await task.value
    #expect(await eventually { topic.subscriptionCount == 0 })
}

@Test func sentMessageIDWaitReadsAgainOnlyAfterDatabaseTick() async throws {
    let changes = Topic<Void>()
    let sentRows = Protected<[DatabaseTickWaits.SentMessageID]>([])
    let queryCount = Protected(0)

    let task = Task {
        try await DatabaseTickWaits.sentMessageIDs(
            text: nil,
            timeout: 1,
            changes: changes
        ) {
            queryCount.withLock { $0 += 1 }
            return sentRows.read()
        }
    }

    #expect(await eventually { queryCount.read() == 1 })
    try await Task.sleep(forTimeInterval: 0.1)
    #expect(queryCount.read() == 1)

    sentRows.withLock {
        $0 = [(rowID: 11, guid: "message-11")]
    }
    changes.broadcast(())

    let result = try await task.value
    #expect(result.map(\.rowID) == [11])
    #expect(queryCount.read() == 2)
    #expect(await eventually { changes.subscriptionCount == 0 })
}

// Proves the backstop re-queries WITHOUT any broadcast(()): the result flips
// after the (short, injected) backstop interval and is picked up by the poll,
// well before the much-longer timeout.
@Test func sentMessageIDWaitReQueriesOnBackstopWithoutTick() async throws {
    let changes = Topic<Void>()
    let sentRows = Protected<[DatabaseTickWaits.SentMessageID]>([])
    let startedAt = Date()

    Task {
        try? await Task.sleep(forTimeInterval: 0.15)
        sentRows.withLock {
            $0 = [(rowID: 11, guid: "message-11")]
        }
    }

    let result = try await DatabaseTickWaits.sentMessageIDs(
        text: nil,
        timeout: 2.5,
        changes: changes,
        backstopInterval: 0.1
    ) {
        sentRows.read()
    }

    #expect(result.map(\.rowID) == [11])
    // Never broadcast: the backstop alone must have driven the re-query.
    #expect(Date().timeIntervalSince(startedAt) < 1.0)
    #expect(await eventually { changes.subscriptionCount == 0 })
}

// Proves caller cancellation propagates: a never-satisfied wait with a long
// timeout finishes promptly when its task is cancelled, and unsubscribes.
@Test func sentMessageIDWaitPropagatesCallerCancellation() async throws {
    let changes = Topic<Void>()

    let task = Task {
        try await DatabaseTickWaits.sentMessageIDs(
            text: nil,
            timeout: 5,
            changes: changes
        ) {
            []
        }
    }

    #expect(await eventually { changes.subscriptionCount == 1 })
    task.cancel()

    let startedAt = Date()
    await #expect(throws: (any Error).self) {
        _ = try await task.value
    }
    #expect(Date().timeIntervalSince(startedAt) < 1.0)
    #expect(await eventually { changes.subscriptionCount == 0 })
}

@Test func sentMessageIDWaitReturnsPartialLinkSendAfterLinkTimeout() async throws {
    let changes = Topic<Void>()
    let queryCount = Protected(0)
    let startedAt = Date()

    let result = try await DatabaseTickWaits.sentMessageIDs(
        text: "https://one.example https://two.example",
        timeout: 1,
        changes: changes,
        linkTimeout: 0.05
    ) {
        queryCount.withLock { $0 += 1 }
        return [(rowID: 11, guid: "message-11")]
    }

    #expect(result.map(\.rowID) == [11])
    #expect(queryCount.read() == 2)
    #expect(Date().timeIntervalSince(startedAt) < 0.5)
    #expect(await eventually { changes.subscriptionCount == 0 })
}

@Test func sentThreadIDWaitReadsAgainOnlyAfterDatabaseTick() async throws {
    let changes = Topic<Void>()
    let threadIDs = Protected<[String?]>([nil])
    let queryCount = Protected(0)

    let task = Task {
        try await DatabaseTickWaits.sentThreadIDs(
            timeout: 1,
            changes: changes
        ) {
            queryCount.withLock { $0 += 1 }
            return threadIDs.read()
        }
    }

    #expect(await eventually { queryCount.read() == 1 })
    try await Task.sleep(forTimeInterval: 0.1)
    #expect(queryCount.read() == 1)

    threadIDs.withLock {
        $0 = ["thread-1"]
    }
    changes.broadcast(())

    let result = try await task.value
    #expect(result == ["thread-1"])
    #expect(queryCount.read() == 2)
    #expect(await eventually { changes.subscriptionCount == 0 })
}

@Test func loadedAttachmentWaitReadsAgainOnlyAfterDatabaseTick() async throws {
    let changes = Topic<Void>()
    let currentMessage = Protected(messageWithAttachmentLoading(true))
    let queryCount = Protected(0)

    let task = Task {
        try await DatabaseTickWaits.loadedAttachment(
            messageID: "message-1",
            timeout: 1,
            changes: changes,
            loadMessage: {
                queryCount.withLock { $0 += 1 }
                return currentMessage.read()
            },
            terminalAttachmentFailureState: {
                nil
            }
        )
    }

    #expect(await eventually { queryCount.read() == 1 })
    try await Task.sleep(forTimeInterval: 0.1)
    #expect(queryCount.read() == 1)

    currentMessage.withLock {
        $0 = messageWithAttachmentLoading(false)
    }
    changes.broadcast(())

    let result = try await task.value
    #expect(result.attachments?.first?.loading == false)
    #expect(queryCount.read() == 2)
    #expect(await eventually { changes.subscriptionCount == 0 })
}

@Test func sentMessageIDWaitThrowsOnTimeoutWithoutTick() async throws {
    let changes = Topic<Void>()
    await #expect(throws: (any Error).self) {
        try await DatabaseTickWaits.sentMessageIDs(
            text: nil,
            timeout: 0.2,
            changes: changes
        ) {
            []
        }
    }
    #expect(await eventually { changes.subscriptionCount == 0 })
}

@Test func sentThreadIDWaitReturnsPartialAfterDeadline() async throws {
    let changes = Topic<Void>()
    let result = try await DatabaseTickWaits.sentThreadIDs(
        timeout: 0.2,
        changes: changes
    ) {
        [nil, "thread-2"]
    }

    #expect(result == [nil, "thread-2"])
    #expect(await eventually { changes.subscriptionCount == 0 })
}

@Test func loadedAttachmentWaitThrowsWhenMessageHasNoAttachments() async throws {
    let changes = Topic<Void>()
    await #expect(throws: (any Error).self) {
        try await DatabaseTickWaits.loadedAttachment(
            messageID: "message-1",
            timeout: 1,
            changes: changes,
            loadMessage: { messageWithNoAttachments() },
            terminalAttachmentFailureState: { nil }
        )
    }
    #expect(await eventually { changes.subscriptionCount == 0 })
}

@Test func loadedAttachmentWaitThrowsWhenMessageNotFound() async throws {
    let changes = Topic<Void>()
    await #expect(throws: (any Error).self) {
        try await DatabaseTickWaits.loadedAttachment(
            messageID: "message-1",
            timeout: 1,
            changes: changes,
            loadMessage: { nil },
            terminalAttachmentFailureState: { nil }
        )
    }
    #expect(await eventually { changes.subscriptionCount == 0 })
}

@Test func loadedAttachmentWaitThrowsOnTerminalFailureState() async throws {
    let changes = Topic<Void>()
    await #expect(throws: (any Error).self) {
        try await DatabaseTickWaits.loadedAttachment(
            messageID: "message-1",
            timeout: 1,
            changes: changes,
            loadMessage: { messageWithAttachmentLoading(true) },
            terminalAttachmentFailureState: { Attachment.IMFileTransferState.error }
        )
    }
    #expect(await eventually { changes.subscriptionCount == 0 })
}

@Test func loadedAttachmentWaitThrowsOnTimeoutWithoutTick() async throws {
    let changes = Topic<Void>()
    await #expect(throws: (any Error).self) {
        try await DatabaseTickWaits.loadedAttachment(
            messageID: "message-1",
            timeout: 0.2,
            changes: changes,
            loadMessage: { messageWithAttachmentLoading(true) },
            terminalAttachmentFailureState: { nil }
        )
    }
    #expect(await eventually { changes.subscriptionCount == 0 })
}

// Guards the lock-release-before-finish() fix: calling finish() under the lock
// would re-enter onTermination on the non-reentrant os_unfair_lock and deadlock.
@Test func finishCurrentSubscribersDoesNotDeadlockAndClearsSubscriptions() {
    let topic = Topic<Void>()
    let streams = (0 ..< 5).map { _ in topic.subscribe() }
    #expect(topic.subscriptionCount == 5)

    topic.finishCurrentSubscribers()

    #expect(topic.subscriptionCount == 0)
    withExtendedLifetime(streams) {}
}

private func messageWithNoAttachments() -> PlatformSDK.Message {
    PlatformSDK.Message(
        id: "message-1",
        timestamp: 1,
        senderID: "sender-1",
        attachments: []
    )
}

private func messageWithAttachmentLoading(_ loading: Bool) -> PlatformSDK.Message {
    PlatformSDK.Message(
        id: "message-1",
        timestamp: 1,
        senderID: "sender-1",
        attachments: [
            PlatformSDK.Attachment(
                id: "attachment-1",
                type: .img,
                loading: loading
            ),
        ]
    )
}

private func eventually(timeout: TimeInterval = 1, _ predicate: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() {
            return true
        }
        try? await Task.sleep(forTimeInterval: 0.01)
    }
    return predicate()
}
