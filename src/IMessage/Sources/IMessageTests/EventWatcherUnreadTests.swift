import Foundation
@testable import IMDatabase
@testable import IMessage
import PlatformSDK
import Testing

@Test func unreadDiffOnlyEmitsStateSyncsForFetchedChats() throws {
    let unchangedThreadID = "any;-;unchanged@example.invalid"
    var trackedChatStates = [
        "any;-;changed@example.invalid": TimestampedChatState(minting: chatState(unreadCount: 0, seconds: 1)),
        unchangedThreadID: TimestampedChatState(minting: chatState(unreadCount: 1, seconds: 1)),
    ]

    let events = EventWatcher.unreadDiffEvents(
        currentChatStates: [
            "any;-;changed@example.invalid": chatState(unreadCount: 1, seconds: 2),
        ],
        deletedChatGUIDs: [],
        trackedChatStates: &trackedChatStates
    )

    let eventObject = try #require(events.first?.jsonObject())
    let entries = try #require(eventObject["entries"] as? [JSONObject])
    let patch = try #require(entries.first)

    #expect(events.count == 1)
    #expect(eventObject["objectName"] as? String == "thread")
    #expect(eventObject["mutationType"] as? String == "update")
    #expect(patch["isMarkedUnread"] as? Bool == true)
    #expect(patch["unreadCount"] == nil)
    #expect(trackedChatStates[unchangedThreadID]?.state == chatState(unreadCount: 1, seconds: 1))
}

@Test func unreadDiffEmitsUnreadCountZeroWhenChatBecomesRead() throws {
    let threadID = "any;-;read@example.invalid"
    var trackedChatStates = [
        threadID: TimestampedChatState(minting: chatState(unreadCount: 2, seconds: 1)),
    ]

    let events = EventWatcher.unreadDiffEvents(
        currentChatStates: [
            threadID: chatState(unreadCount: 0, seconds: 3),
        ],
        deletedChatGUIDs: [],
        trackedChatStates: &trackedChatStates
    )

    let eventObject = try #require(events.first?.jsonObject())
    let entries = try #require(eventObject["entries"] as? [JSONObject])
    let patch = try #require(entries.first)

    #expect(events.count == 1)
    #expect(patch["isMarkedUnread"] as? Bool == false)
    #expect(patch["unreadCount"] as? Int == 0)
    #expect(patch["lastReadMessageSortKey"] as? Double == 3_000)
}

@Test func unreadDiffEmitsDeleteThreadsFromReconciliation() throws {
    let keptThreadID = "any;-;kept@example.invalid"
    let deletedThreadID = "any;-;deleted@example.invalid"
    var trackedChatStates = [
        keptThreadID: TimestampedChatState(minting: chatState(unreadCount: 0, seconds: 1)),
        deletedThreadID: TimestampedChatState(minting: chatState(unreadCount: 1, seconds: 1)),
    ]

    let events = EventWatcher.unreadDiffEvents(
        currentChatStates: [:],
        deletedChatGUIDs: [deletedThreadID],
        trackedChatStates: &trackedChatStates
    )

    let eventObject = try #require(events.first?.jsonObject())

    #expect(events.count == 1)
    #expect(eventObject["objectName"] as? String == "thread")
    #expect(eventObject["mutationType"] as? String == "delete")
    #expect(eventObject["entries"] as? [String] == [Hasher.thread.tokenizeRemembering(pii: deletedThreadID)])
    #expect(trackedChatStates[keptThreadID] != nil)
    #expect(trackedChatStates[deletedThreadID] == nil)
}

@Test func fullUnreadDiffPassReconcilesTrackedChatsMissingFromCurrentState() {
    let deletedThreadID = "any;-;deleted@example.invalid"
    let alreadyDeletedThreadID = "any;-;already-deleted@example.invalid"
    let keptThreadID = "any;-;kept@example.invalid"

    let deletedChatGUIDs = EventWatcher.deletedChatGUIDsForUnreadDiff(
        currentChatStates: [
            keptThreadID: chatState(unreadCount: 0, seconds: 2),
        ],
        deletedChatGUIDs: [alreadyDeletedThreadID],
        trackedChatGUIDs: [alreadyDeletedThreadID, deletedThreadID, keptThreadID],
        forceFullUnreadStatePass: true
    )

    #expect(deletedChatGUIDs == [alreadyDeletedThreadID, deletedThreadID])
}

@Test func nonForcedUnreadDiffPassReturnsExplicitDeletionsAsIs() {
    let deletedThreadID = "any;-;deleted@example.invalid"
    let keptThreadID = "any;-;kept@example.invalid"

    let deletedChatGUIDs = EventWatcher.deletedChatGUIDsForUnreadDiff(
        currentChatStates: [
            keptThreadID: chatState(unreadCount: 0, seconds: 2),
        ],
        deletedChatGUIDs: [deletedThreadID],
        trackedChatGUIDs: [deletedThreadID, keptThreadID],
        forceFullUnreadStatePass: false
    )

    #expect(deletedChatGUIDs == [deletedThreadID])
}

@Test func nonForcedUnreadDiffPassDeduplicatesExplicitDeletions() {
    let deletedThreadID = "any;-;deleted@example.invalid"

    let deletedChatGUIDs = EventWatcher.deletedChatGUIDsForUnreadDiff(
        currentChatStates: [:],
        deletedChatGUIDs: [deletedThreadID, deletedThreadID, deletedThreadID],
        trackedChatGUIDs: [deletedThreadID],
        forceFullUnreadStatePass: false
    )

    #expect(deletedChatGUIDs == [deletedThreadID])
}

@Test func nonForcedUnreadDiffPassDoesNotReconcileTrackedChatsMissingFromCurrentState() {
    // The key non-forced-branch assertion: reconciliation of tracked-but-absent
    // chats must NOT fire when `forceFullUnreadStatePass` is false, because the
    // scoped pass only queries a subset of chats and a chat being absent from
    // `currentChatStates` is not evidence of deletion.
    let trackedButAbsentThreadID = "any;-;tracked-absent@example.invalid"
    let keptThreadID = "any;-;kept@example.invalid"

    let deletedChatGUIDs = EventWatcher.deletedChatGUIDsForUnreadDiff(
        currentChatStates: [
            keptThreadID: chatState(unreadCount: 0, seconds: 2),
        ],
        deletedChatGUIDs: [],
        trackedChatGUIDs: [trackedButAbsentThreadID, keptThreadID],
        forceFullUnreadStatePass: false
    )

    #expect(deletedChatGUIDs.isEmpty)
}

@Test func nextPassDecisionIncrementsButDoesNotForceOnFirstTick() {
    let decision = EventWatcher.nextPassDecision(currentCount: 0, forceNow: false, interval: 50)
    #expect(decision.force == false)
    #expect(decision.newCount == 1)
}

@Test func nextPassDecisionForcesAndResetsAtInterval() {
    let decision = EventWatcher.nextPassDecision(currentCount: 49, forceNow: false, interval: 50)
    #expect(decision.force == true)
    #expect(decision.newCount == 0)
}

@Test func nextPassDecisionForcesImmediatelyWhenForceNowRegardlessOfCounter() {
    let decision = EventWatcher.nextPassDecision(currentCount: 3, forceNow: true, interval: 50)
    #expect(decision.force == true)
    #expect(decision.newCount == 0)
}

@Test func nextPassDecisionResetsCounterAcrossCycles() {
    // Walk through two full cycles to confirm the counter resets cleanly.
    var count = 0
    for _ in 1..<50 {
        let step = EventWatcher.nextPassDecision(currentCount: count, forceNow: false, interval: 50)
        #expect(step.force == false)
        count = step.newCount
    }
    let firstFire = EventWatcher.nextPassDecision(currentCount: count, forceNow: false, interval: 50)
    #expect(firstFire.force == true)
    #expect(firstFire.newCount == 0)

    count = firstFire.newCount
    for _ in 1..<50 {
        let step = EventWatcher.nextPassDecision(currentCount: count, forceNow: false, interval: 50)
        #expect(step.force == false)
        count = step.newCount
    }
    let secondFire = EventWatcher.nextPassDecision(currentCount: count, forceNow: false, interval: 50)
    #expect(secondFire.force == true)
    #expect(secondFire.newCount == 0)
}

private func chatState(unreadCount: Int, seconds: TimeInterval) -> ChatState {
    ChatState(
        unreadCount: unreadCount,
        lastReadMessageTimestamp: date(seconds: seconds)
    )
}

private func date(seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}
