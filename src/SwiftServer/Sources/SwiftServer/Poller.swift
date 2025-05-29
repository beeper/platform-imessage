import IMDatabase

import Logging

private let log = Logger(swiftServerLabel: "poller")

private func traceUnreads(_ message: @autoclosure () -> Logger.Message) {
    guard Defaults.swiftServer.bool(forKey: DefaultsKeys.pollerTraceUnreads) else { return }
    log.debug(message())
}

final class Poller {
    typealias ServerEventSender = @Sendable (sending [PASEvent]) async throws -> Void

    var db: IMDatabase

    var unreadStates: IMDatabase.UnreadStates?

    private var sender: ServerEventSender

    init(serverEventSender sender: @escaping ServerEventSender) throws {
        db = try IMDatabase()
        self.sender = sender
    }

    func pollForever() async throws {
        unreadStates = try db.queryUnreadStates()
        try db.beginListeningForChanges()

        for try await _ in db.changes.subscribe() {
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

            // TODO: Synthesize thread refresh events.

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
            eventsToSend.append(.stateSyncThread(id: hashedThreadID, properties: [
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

extension ChatRef: @retroactive CustomStringConvertible {
    public var description: String {
        "chat#\(guid.map(Hasher.participant.tokenizeRemembering(pii:)) ?? String(rowID!))"
    }
}
