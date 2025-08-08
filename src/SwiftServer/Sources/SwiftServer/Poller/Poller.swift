import Foundation
import IMDatabase
import Logging

private let log = Logger(swiftServerLabel: "poller")

struct TimestampedUnreadState {
    var lastUpdated: Date
    var state: UnreadState

    init(minting state: UnreadState) {
        lastUpdated = Date()
        self.state = state
    }
}

final class Poller {
    typealias ServerEventSender = @Sendable (sending [PASEvent]) async throws -> Void

    var db: IMDatabase

    /// Tracks the last known unread state of every chat.
    var unreadStates = [ChatRef: TimestampedUnreadState]()
    var updatesCursor: MessageUpdatesCursor

    private var sender: ServerEventSender

    init(serverEventSender sender: @escaping ServerEventSender, initialUpdatesCursor: MessageUpdatesCursor) throws {
        self.db = try IMDatabase()
        if SwiftServerDefaults[\.pollerTraceChangeListening] {
            log.debug("tracing change listening, telling IMDatabase to be noisy")
            self.db.noisy = true
        }
        self.sender = sender
        self.updatesCursor = initialUpdatesCursor
    }

    func pollForever() async throws {
        unreadStates = try db.queryUnreadStates().mapValues { state in
            TimestampedUnreadState(minting: state)
        }
        try db.beginListeningForChanges()

        poll: for try await _ in db.changes.subscribe() {
            guard !Task.isCancelled else {
                log.info("woke up in response to db change but poller task was canceled, bailing")
                return
            }

            if SwiftServerDefaults[\.pollerTraceChangeListening] {
                log.debug("poller was informed about database change")
            }

            var eventsToSend = [PASEvent]()

            do {
                // Query unread states, compare to the previous set, and persist them.
                try eventsToSend.append(contentsOf: pollUnreads())

                // Ditto, but for any new messages/read state changes.
                try eventsToSend.append(contentsOf: pollMessageUpdates())
            }

            // TODO: Handle unsends and edits that occur from outside of Beeper.

            guard !eventsToSend.isEmpty else { continue }
            do {
                guard !Task.isCancelled else {
                    log.info("had \(eventsToSend.count) event(s) to send but poller task was canceled, bailing")
                    return
                }
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
