import Foundation
import IMDatabase
import Logging

private let log = Logger(swiftServerLabel: "poller")

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

            do {
                // Query unread states, compare to the previous set, and persist them.
                try eventsToSend.append(contentsOf: pollUnreads())

                // Ditto, but for any new messages/read state changes.
                try eventsToSend.append(contentsOf: pollMessageUpdates())
            }

            // TODO: Handle unsends and edits that occur from outside of Beeper.

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
