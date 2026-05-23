import Collections
import Foundation
import IMDatabase
import Logging
import PlatformSDK

struct TimestampedChatState {
    var lastUpdated: Date
    var state: ChatState

    init(minting state: ChatState) {
        lastUpdated = Date()
        self.state = state
    }
}

struct PendingLinkPreviewCandidate {
    let firstSeen: Date
    let chatGUID: String
}

final class EventWatcher {
    static let logger = Logger(imessageLabel: "event-watcher")

    var db: IMDatabase

    /// Tracks the last known state of every chat.
    var chatStates = [String: TimestampedChatState]()
    var updatesCursor: MessageUpdatesCursor
    var pendingUnresolvedNewMessageRowIDs = OrderedDictionary<Int, Date>()
    var pendingLinkPreviewCandidates = OrderedDictionary<Int, PendingLinkPreviewCandidate>()

    let currentUserID: String
    let accountID: String
    private var sender: PlatformAPI.EventCallback
    private let reportErrorMessage: PlatformAPI.ReportErrorMessage?

    init(
        serverEventSender sender: @escaping PlatformAPI.EventCallback,
        initialUpdatesCursor: MessageUpdatesCursor,
        currentUserID: String,
        accountID: String,
        db: IMDatabase? = nil,
        reportErrorMessage: PlatformAPI.ReportErrorMessage? = nil
    ) throws {
        if let db {
            self.db = db
        } else {
            self.db = try IMDatabase()
        }

        if Defaults.eventWatcherTraceChangeListening {
            Self.logger.debug("tracing change listening, telling IMDatabase to be noisy")
            self.db.noisy = true
        }

        self.sender = sender
        self.updatesCursor = initialUpdatesCursor
        self.currentUserID = currentUserID
        self.accountID = accountID
        self.reportErrorMessage = reportErrorMessage
    }

    func watchForever() async throws {
        chatStates = try db.chatStates().mapValues(TimestampedChatState.init)
        try db.beginListeningForChanges()

        for try await _ in db.changes.subscribe() {
            guard !Task.isCancelled else {
                Self.logger.info("woke up in response to db change but event watcher task was canceled, bailing")
                return
            }

            if Defaults.eventWatcherTraceChangeListening {
                Self.logger.debug("event watcher was informed about database change")
            }

            var eventsToSend: [ServerEvent] = []

            do {
                // Query unread states, compare to the previous set, and persist them.
                try eventsToSend.append(contentsOf: diffChatStates())
                // Ditto, but for any new messages/read state changes.
                let messageUpdateEvents = try await collectMessageUpdateEvents()
                eventsToSend.append(contentsOf: messageUpdateEvents)
            } catch is CancellationError {
                Self.logger.info("event watcher task was canceled while collecting events, bailing")
                return
            } catch {
                Self.logger.error("couldn't collect event watcher events: \(String(reflecting: error)), continuing")
                try? reportErrorMessage?("imsg event watcher: couldn't collect events: \(String(reflecting: error))")
                continue
            }

            guard !eventsToSend.isEmpty else { continue }

            do {
                guard !Task.isCancelled else {
                    Self.logger.info("had \(eventsToSend.count) event(s) to send but event watcher task was canceled, bailing")
                    return
                }
                #if DEBUG
                Self.logger.debug("sending \(eventsToSend.count) event(s) to PAS")
                #endif
                try await sender(eventsToSend)
            } catch {
                Self.logger.error("couldn't send events to PAS: \(String(reflecting: error)), continuing")
                try? reportErrorMessage?("imsg event watcher: couldn't send events to PAS: \(String(reflecting: error))")
            }
        }
    }
}
