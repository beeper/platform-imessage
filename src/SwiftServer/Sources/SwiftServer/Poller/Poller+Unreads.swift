import IMDatabase
import NodeAPI
import Logging

private let log = Logger(swiftServerLabel: "poller.unreads")

private func traceUnreads(_ message: @autoclosure () -> Logger.Message) {
    guard SwiftServerDefaults[\.pollerTraceUnreads] else { return }
    log.debug(message())
}

extension Poller {
    func pollUnreads() throws -> [PASEvent] {
        // Grab the latest set, and remember them for the next poll.
        let currentStates = try db.queryUnreadStates()

        var eventsToSend = [PASEvent]()
        var changes = 0

        for (chat, currentState) in currentStates {
            guard unreadStates[chat]?.state != currentState else {
                // Unread state didn't change, so a state sync is unnecessary.
                continue
            }
            defer { changes += 1 }

            guard let guid = chat.guid else {
                log.error("didn't receive a guid for chat that underwent an unread state change")
                continue
            }

            // Minting a new timestamped unread state like this also ensures
            // that we handle new (not just updated) chats correctly.
            let fresh = TimestampedUnreadState(minting: currentState)
            unreadStates[chat] = fresh

            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: guid)
            let lastReadMessageSortKey = (currentState.lastReadMessageTimestamp.timeIntervalSince1970 * 1_000).rounded()
            let isUnread = currentState.unreadCount > 0
            let markedUnreadUpdatedAt = Int(fresh.lastUpdated.timeIntervalSince1970 * 1000)
            var patch: [String: any NodePropertyConvertible] = [
                "lastReadMessageSortKey": lastReadMessageSortKey,

                // The renderer avoids sending a read receipt if it can see that
                // the message that it's currently reading up to is older than
                // the `lastReadMessageSortKey`. However, our `lastReadMessageSortKey`
                // is sourced from iMessage itself and we can't necessarily rely
                // on it to perfectly align with how we model unreads. Indeed, the
                // "last read message timestamp" from iMessage can seemingly be
                // increased even when no new messages have been sent. That is,
                // it's more like a "when did the user last check in this chat"
                // timestamp instead of literally being the sort key of the last
                // read message.
                //
                // Therefore, when the chat is unread in some form, pretend that
                // it was manually marked as unread so that it can always send
                // a read receipt, despite whatever `lastReadMessageSortKey` is.
                //
                // See: https://github.com/beeper/beeper-desktop-new/blob/489c8b4974497c431c8d18d7d5eecc21afdf66b7/src/renderer/stores/ThreadStore.ts#L2109
                "isMarkedUnread": isUnread,

                // Part of the "is this room archived?" logic involves comparing
                // this thread property to when the thread was archived by the user.
                // However, if we don't send this, then Desktop falls back to
                // `timestamp`. This can result in flashes when sending a message
                // and immediately archiving before the message send completes,
                // because `timestamp` is updated to a instant that succeeds
                // the archive action.
                //
                // TODO(skip): This might not be necessary anymore since we
                // adopted the stream order concept.
                "markedUnreadUpdatedAt": markedUnreadUpdatedAt,
            ]

            traceUnreads("chat \(chat) patch: lastReadMessageSortKey=\(lastReadMessageSortKey), isMarkedUnread=\(isUnread), markedUnreadUpdatedAt=\(markedUnreadUpdatedAt)")

            if currentState.unreadCount == 0 {
                // Sync the fact that the thread became read. This is especially
                // important for bidirectional syncing (i.e. marking a chat as
                // read from the iMessage app itself).
                patch["unreadCount"] = 0
            } else {
                // New messages are going to be synced to the renderer soon;
                // don't sync an `unreadCount` since the renderer will do
                // automatic incrementation on our behalf, as our messages `countsAsUnread`.
                // Otherwise, the unread count will become 2 (in the renderer's memory).
            }

            eventsToSend.append(PASEvent.stateSyncThread(id: hashedThreadID, patch: patch))

            traceUnreads("chat \(chat) unread state changed to: \(fresh)")
        }

        traceUnreads("\(changes) unread state(s) changed this time around")

        return eventsToSend
    }
}
