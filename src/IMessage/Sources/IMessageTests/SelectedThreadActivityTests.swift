import Foundation
@testable import IMessage
import Testing

private final class SelectionOwner {}

@Test func delayedSelectionCannotReplaceOrClearANewerRequest() {
    let owner = SelectionOwner()
    var state = SelectedThreadActivitySelection()
    let firstID = state.begin(owner: ObjectIdentifier(owner))
    let secondID = state.begin(owner: ObjectIdentifier(owner))
    let second = SelectedThreadActivitySelection.Thread(
        requestID: secondID, threadID: "second", sendStatus: { _ in }
    )
    let installedSecond = state.install(second)
    #expect(installedSecond)
    let first = SelectedThreadActivitySelection.Thread(
        requestID: firstID, threadID: "first", sendStatus: { _ in }
    )
    let installedStaleFirst = state.install(first)
    #expect(!installedStaleFirst)
    state.clear(ifCurrent: firstID)
    #expect(state.thread?.threadID == "second")
}

@Test func deselectionAndDisposalInvalidatePendingSelectionLookups() {
    let owner = SelectionOwner()
    let otherOwner = SelectionOwner()
    var state = SelectedThreadActivitySelection()
    let firstID = state.begin(owner: ObjectIdentifier(owner))
    let delayed = SelectedThreadActivitySelection.Thread(
        requestID: firstID, threadID: "first", sendStatus: { _ in }
    )
    _ = state.begin(owner: ObjectIdentifier(owner)) // nil selection still reserves a newer request
    let installedDeselectedRequest = state.install(delayed)
    #expect(!installedDeselectedRequest)
    let nextID = state.begin(owner: ObjectIdentifier(owner))
    let next = SelectedThreadActivitySelection.Thread(
        requestID: nextID, threadID: "next", sendStatus: { _ in }
    )
    state.clear(ifOwnedBy: ObjectIdentifier(otherOwner))
    let installedCurrentRequest = state.install(next)
    #expect(installedCurrentRequest)
    state.clear(ifOwnedBy: ObjectIdentifier(owner))
    #expect(state.thread == nil)
    let installedDisposedRequest = state.install(next)
    #expect(!installedDisposedRequest)
}

@Test func activityDeduplicationIsScopedToEachSelectionRequest() {
    var cache = ThreadActivityObservationCache()
    let first = UUID()
    let second = UUID()
    let sentFirst = cache.shouldSend(.unknown, requestID: first)
    #expect(sentFirst)
    let sentFirstAgain = cache.shouldSend(.unknown, requestID: first)
    #expect(!sentFirstAgain)
    // Two chats can have identical presence/typing state; both need an initial event.
    let sentSecond = cache.shouldSend(.unknown, requestID: second)
    #expect(sentSecond)
    let sentSecondAgain = cache.shouldSend(.unknown, requestID: second)
    #expect(!sentSecondAgain)
    let sentReselection = cache.shouldSend(.unknown, requestID: UUID())
    #expect(sentReselection) // reselecting the same chat
}

@Test func activityDeduplicationRefreshesTypingAfterThirtySeconds() {
    var cache = ThreadActivityObservationCache()
    let requestID = UUID()
    let now = Date()
    let typing = ThreadActivityObservation(activityType: .typing, presenceStatus: nil, didObservePresence: true)
    let sentTyping = cache.shouldSend(typing, requestID: requestID, now: now)
    #expect(sentTyping)
    let sentTooSoon = cache.shouldSend(typing, requestID: requestID, now: now.addingTimeInterval(29))
    #expect(!sentTooSoon)
    let sentRefresh = cache.shouldSend(typing, requestID: requestID, now: now.addingTimeInterval(31))
    #expect(sentRefresh)
}
