import IMDatabase
import Logging

private let log = Logger(swiftServerLabel: "poller.unreads")

private func traceUnreads(_ message: @autoclosure () -> Logger.Message) {
    guard Defaults.swiftServer.bool(forKey: DefaultsKeys.pollerTraceUnreads) else { return }
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
            eventsToSend.append(PASEvent.stateSyncThread(id: hashedThreadID, properties: [
                "unreadCount": currentState.unreadCount,
                "lastReadMessageSortKey": String(currentState.lastReadMessageTimestamp.nanosecondsSinceReferenceDate),

                // This is necessary as Beeper Desktop refuses to mark a thread
                // as read under certain conditions that can be triggered by
                // manually marking a thread as unread in iMessage itself.
                // See: https://github.com/beeper/beeper-desktop-new/blob/489c8b4974497c431c8d18d7d5eecc21afdf66b7/src/renderer/stores/ThreadStore.ts#L2109
                //
                // Since we "own" the unread state, force our way through certain code paths by
                // pretending that everything is (manually) marked unread all the time. On our
                // side, it doesn't seem to be possible to discern between a chat becoming unread
                // due to a new message arriving or being manually marked as such.
                "isMarkedUnread": currentState.unreadCount > 0,

                // Part of the "is this room archived?" logic involves comparing
                // this thread property to when the thread was archived by the user.
                // However, if we don't send this, then Desktop falls back to
                // `timestamp`. This can result in flashes when sending a message
                // and immediately archiving before the message send completes,
                // because `timestamp` is updated to a instant that succeeds
                // the archive action.
                "markedUnreadUpdatedAt": Int(fresh.lastUpdated.timeIntervalSince1970 * 1000),
            ]))

            traceUnreads("chat \(chat) unread state changed to: \(fresh)")
        }

        traceUnreads("\(changes) unread state(s) changed this time around")

        return eventsToSend
    }
}
