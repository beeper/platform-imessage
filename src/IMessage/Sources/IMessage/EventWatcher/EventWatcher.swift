import Foundation
import IMDatabase
import Logging
import PlatformSDK

private let log = Logger(imessageLabel: "event-watcher")

struct TimestampedChatState {
    var lastUpdated: Date
    var state: ChatState

    init(minting state: ChatState) {
        lastUpdated = Date()
        self.state = state
    }
}

final class EventWatcher {
    typealias ServerEventSender = @Sendable (sending [ServerEvent]) async throws -> Void
    typealias ReportErrorMessage = @Sendable (String) -> Void

    var db: IMDatabase

    /// Tracks the last known state of every chat.
    var chatStates = [ChatRef: TimestampedChatState]()
    var updatesCursor: MessageUpdatesCursor

    private var sender: ServerEventSender
    private let reportErrorMessage: ReportErrorMessage?

    init(
        serverEventSender sender: @escaping ServerEventSender,
        initialUpdatesCursor: MessageUpdatesCursor,
        reportErrorMessage: ReportErrorMessage? = nil
    ) throws {
        self.db = try IMDatabase()
        if Defaults.eventWatcherTraceChangeListening {
            log.debug("tracing change listening, telling IMDatabase to be noisy")
            self.db.noisy = true
        }
        self.sender = sender
        self.updatesCursor = initialUpdatesCursor
        self.reportErrorMessage = reportErrorMessage
    }

    func watchForever() async throws {
        chatStates = try db.chatStates().mapValues { state in
            TimestampedChatState(minting: state)
        }
        try db.beginListeningForChanges()

        for try await _ in db.changes.subscribe() {
            guard !Task.isCancelled else {
                log.info("woke up in response to db change but event watcher task was canceled, bailing")
                return
            }

            if Defaults.eventWatcherTraceChangeListening {
                log.debug("event watcher was informed about database change")
            }

            var eventsToSend = [ServerEvent]()

            do {
                // Query unread states, compare to the previous set, and persist them.
                try eventsToSend.append(contentsOf: diffChatStates())

                // Ditto, but for any new messages/read state changes.
                try eventsToSend.append(contentsOf: collectMessageUpdateEvents())
            }

            guard !eventsToSend.isEmpty else { continue }
            do {
                guard !Task.isCancelled else {
                    log.info("had \(eventsToSend.count) event(s) to send but event watcher task was canceled, bailing")
                    return
                }
                #if DEBUG
                log.debug("sending \(eventsToSend.count) event(s) to PAS")
                #endif
                try await sender(eventsToSend)
            } catch {
                log.error("couldn't send events to PAS: \(String(reflecting: error)), continuing")
                reportErrorMessage?("imsg event watcher: couldn't send events to PAS: \(String(reflecting: error))")
            }
        }
    }
}
