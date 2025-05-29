import Foundation
import IMDatabase
import Logging

private let log = Logger(swiftServerLabel: "poller")

private func traceUnreads(_ message: @autoclosure () -> Logger.Message) {
    guard Defaults.swiftServer.bool(forKey: DefaultsKeys.pollerTraceUnreads) else { return }
    log.debug(message())
}

private func traceMessageUpdates(_ message: @autoclosure () -> Logger.Message) {
    guard Defaults.swiftServer.bool(forKey: DefaultsKeys.pollerTraceMessageUpdates) else { return }
    log.debug(message())
}

final class Poller {
    typealias ServerEventSender = @Sendable (sending [PASEvent]) async throws -> Void

    var db: IMDatabase

    /// Tracks the last known unread state of every chat.
    var unreadStates: IMDatabase.UnreadStates?
    var updatesCursor: MessageUpdatesCursor

    private var sender: ServerEventSender

    init(serverEventSender sender: @escaping ServerEventSender, initialUpdatesCursor: MessageUpdatesCursor) throws {
        self.db = try IMDatabase()
        self.sender = sender
        self.updatesCursor = initialUpdatesCursor
    }

    func pollForever() async throws {
        unreadStates = try db.queryUnreadStates()
        try db.beginListeningForChanges()

        poll: for try await _ in db.changes.subscribe() {
#if DEBUG
            log.debug("poller was informed about database change")
#endif
            // TODO: Handle cancellation.
            var eventsToSend = [PASEvent]()

            // Query unread states and compare to the previous set, synthesizing
            // `PASEvent`s as necessary.
            do {
                // Grab the latest set, and remember them for the next poll.
                let newStates = try db.queryUnreadStates()
                defer { unreadStates = newStates }

                if let previousStates = unreadStates {
                    eventsToSend.append(contentsOf: threadStateSyncEvents(fromLatest: newStates, diffingWithOld: previousStates))
                }
            }

            // Query for updated chats.
            updates: do {
                let lastRowID = updatesCursor.lastRowID
                let lastDateRead = updatesCursor.lastDateRead

                // TODO: Maybe move the cursor type into `IMDatabase` and have this
                // TODO: method accept it.
                let queryResult = try db.chats(withMessagesNewerThanRowID: lastRowID, orReadSince: lastDateRead)
                traceMessageUpdates("updated messages query returned \(queryResult.updatedChats.count) updated chat(s)")
                guard !queryResult.updatedChats.isEmpty else {
                    traceMessageUpdates("no chats updated this time around")
                    break updates
                }
                guard let newLastRowID = queryResult.latestMessageRowID else {
                    log.error("didn't have new rowid cursor despite having updated chats?")
                    break updates
                }

                defer {
                    let newCursor = MessageUpdatesCursor(
                        lastRowID: newLastRowID,
                        // Inherit the `lastDateRead` if it hasn't changed.
                        lastDateRead: queryResult.latestMessageDateRead ?? updatesCursor.lastDateRead
                    )
                    traceMessageUpdates("done computing refreshes, updating the messages updates cursor to: \(newCursor)")
                    updatesCursor = newCursor
                }
                try eventsToSend.append(contentsOf: threadRefreshEvents(forUpdatedChats: queryResult))
            }

            guard !eventsToSend.isEmpty else { continue }
            do {
#if DEBUG
                log.debug("sending \(eventsToSend.count) event(s) to PAS")
#endif
                try await sender(eventsToSend)
            } catch {
                log.error("couldn't send events to PAS: \(String(reflecting: error)), continuing")
            }
        }
    }
}

// MARK: - Computing Thread Refresh Events

extension Poller {
    struct MessageUpdatesCursor {
        let lastRowID: Int
        let lastDateRead: Date
    }

    func threadRefreshEvents(forUpdatedChats latest: UpdatedChatsQueryResult) throws -> [PASEvent] {
        guard !latest.updatedChats.isEmpty else { return [] }

        let events: [PASEvent] = latest.updatedChats.compactMap { chat in
            guard let guid = chat.guid else {
                log.error("updated chat didn't have a guid, not vending refresh event")
                return nil
            }
            traceMessageUpdates("chat \(chat) had message updates, queueing a refresh")
            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: guid)
            return PASEvent.refreshMessagesInThread(id: hashedThreadID)
        }

        return events
    }
}

// MARK: - Computing Thread State Sync Events

extension Poller {
    func threadStateSyncEvents(fromLatest new: IMDatabase.UnreadStates, diffingWithOld old: IMDatabase.UnreadStates) -> [PASEvent] {
        var eventsToSend = [PASEvent]()
        var changes = 0

        for (chat, newState) in new where old[chat] != newState {
            defer { changes += 1 }

            guard let guid = chat.guid else {
                log.error("didn't receive a guid for chat that underwent an unread state change")
                continue
            }
            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: guid)
            eventsToSend.append(PASEvent.stateSyncThread(id: hashedThreadID, properties: [
                "unreadCount": newState.unreadCount,
                "lastReadMessageSortKey": String(newState.lastReadMessageTimestamp.nanosecondsSinceReferenceDate),
                // This is necessary as Beeper Desktop refuses to mark a thread
                // as read under certain conditions that can be triggered by
                // manually marking a thread as unread in iMessage itself.
                // See: https://github.com/beeper/beeper-desktop-new/blob/489c8b4974497c431c8d18d7d5eecc21afdf66b7/src/renderer/stores/ThreadStore.ts#L2109
                //
                // Since we "own" the unread state, force our way through certain code paths by
                // pretending that everything is (manually) marked unread all the time. On our
                // side, it doesn't seem to be possible to discern between a chat becoming unread
                // due to a new message arriving or being manually marked as such.
                "isMarkedUnread": newState.unreadCount > 0,
            ]))

            traceUnreads("chat \(chat) unread state changed to: \(newState)")
        }

        traceUnreads("\(changes) unread state(s) changed this time around")
        return eventsToSend
    }
}

// MARK: -

extension ChatRef: @retroactive CustomStringConvertible {
    public var description: String {
        if let guid {
            Hasher.participant.tokenizeRemembering(pii: guid)
        } else {
            "chat#\(rowID!)"
        }
    }
}
