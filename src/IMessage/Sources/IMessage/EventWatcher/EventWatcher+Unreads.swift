import IMDatabase
import Logging
import PlatformSDK

private let log = Logger(imessageLabel: "event-watcher.unreads")

private func traceUnreads(_ message: @autoclosure () -> Logger.Message) {
    guard Defaults.eventWatcherTraceUnreads else { return }
    log.debug(message())
}

extension EventWatcher {
    /// Diffs current chat states against the previous snapshot and returns events for any changes.
    func diffChatStates(
        affectedChatGUIDs: Set<String>,
        deletedChatGUIDs: [String],
        forceFullUnreadStatePass: Bool
    ) throws -> [ServerEvent] {
        let currentChatStates = if forceFullUnreadStatePass {
            try db.chatStates()
        } else {
            try db.chatStates(forChatGUIDs: Array(affectedChatGUIDs))
        }
        let reconciledDeletedChatGUIDs = Self.deletedChatGUIDsForUnreadDiff(
            currentChatStates: currentChatStates,
            deletedChatGUIDs: deletedChatGUIDs,
            trackedChatGUIDs: Set(chatStates.keys),
            forceFullUnreadStatePass: forceFullUnreadStatePass
        )

        return Self.unreadDiffEvents(
            currentChatStates: currentChatStates,
            deletedChatGUIDs: reconciledDeletedChatGUIDs,
            trackedChatStates: &chatStates
        )
    }

    static func deletedChatGUIDsForUnreadDiff(
        currentChatStates: [String: ChatState],
        deletedChatGUIDs: [String],
        trackedChatGUIDs: Set<String>,
        forceFullUnreadStatePass: Bool
    ) -> [String] {
        var seen = Set<String>()
        var reconciledDeletedChatGUIDs = [String]()
        for chatGUID in deletedChatGUIDs where seen.insert(chatGUID).inserted {
            reconciledDeletedChatGUIDs.append(chatGUID)
        }

        if forceFullUnreadStatePass {
            let missingTrackedChatGUIDs = trackedChatGUIDs
                .filter { currentChatStates[$0] == nil }
                .sorted()
            for chatGUID in missingTrackedChatGUIDs where seen.insert(chatGUID).inserted {
                reconciledDeletedChatGUIDs.append(chatGUID)
            }
        }

        return reconciledDeletedChatGUIDs
    }

    static func unreadDiffEvents(
        currentChatStates: [String: ChatState],
        deletedChatGUIDs: [String],
        trackedChatStates chatStates: inout [String: TimestampedChatState]
    ) -> [ServerEvent] {
        var eventsToSend = [ServerEvent]()
        var changes = 0

        for (chatGUID, currentState) in currentChatStates {
            guard chatStates[chatGUID]?.state != currentState else {
                // Unread state didn't change, so a state sync is unnecessary.
                continue
            }

            defer { changes += 1 }

            // Minting a new timestamped chat state like this also ensures
            // that we handle new (not just updated) chats correctly.
            let fresh = TimestampedChatState(minting: currentState)
            chatStates[chatGUID] = fresh

            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: chatGUID)
            let lastReadMessageSortKey = (currentState.lastReadMessageTimestamp.timeIntervalSince1970 * 1000).rounded()
            let isUnread = currentState.unreadCount > 0
            let markedUnreadUpdatedAt = Int(fresh.lastUpdated.timeIntervalSince1970 * 1000)
            var patch: JSONObject = [
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

            traceUnreads("chat \(hashedThreadID) patch: lastReadMessageSortKey=\(lastReadMessageSortKey), isMarkedUnread=\(isUnread), markedUnreadUpdatedAt=\(markedUnreadUpdatedAt)")

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

            eventsToSend.append(ServerEvent.stateSyncThread(id: hashedThreadID, patch: patch))

            traceUnreads("chat \(hashedThreadID) unread state changed to: \(fresh)")
        }

        traceUnreads("\(changes) unread state(s) changed this time around")

        let deletedThreadIDs = deletedChatGUIDs.map { chatGUID -> String in
            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: chatGUID)
            chatStates.removeValue(forKey: chatGUID)
            log.info("chat \(hashedThreadID) was deleted from iMessage")
            return hashedThreadID
        }

        if !deletedThreadIDs.isEmpty {
            eventsToSend.append(
                ServerEvent.deleteThreads(
                    ids: deletedThreadIDs
                )
            )
        }

        return eventsToSend
    }
}
