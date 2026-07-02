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

enum PendingMessageHydrationKind {
    case linkPreview
    case attachmentLoad
}

struct PendingMessageHydrationCandidate {
    let firstSeen: Date
    let chatGUID: String
    let kind: PendingMessageHydrationKind
}

final class EventWatcher {
    static let logger = Logger(imessageLabel: "event-watcher")

    let db: IMDatabase

    /// Tracks the last known state of every chat.
    var chatStates = [String: TimestampedChatState]()
    var updatesCursor: MessageUpdatesCursor
    var pendingUnresolvedNewMessageRowIDs = OrderedDictionary<Int, Date>()
    var pendingMessageHydrationCandidates = OrderedDictionary<Int, PendingMessageHydrationCandidate>()
    /// Rows resolved during the current tick whose pending entries are cleared
    /// only after the tick's events are successfully sent. On a send failure we
    /// leave them pending so the next tick retries: the main-query cursor has
    /// already advanced past these rows, so the pending maps are their only
    /// recovery path. Repopulated from scratch on every tick.
    var newMessageRowIDsAwaitingSendCommit: [Int] = []
    var messageHydrationRowIDsAwaitingSendCommit: [Int] = []
    /// One-shot timer that re-triggers a tick while pending resolution work
    /// remains, so it isn't stranded when the database otherwise goes quiet.
    var pendingWakeTask: Task<Void, Never>?

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
        self.db = try db ?? IMDatabase()

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

    deinit {
        pendingWakeTask?.cancel()
    }

    func watchForever() async throws {
        try await withTaskCancellationHandler {
            chatStates = try db.chatStates().mapValues(TimestampedChatState.init)
            try db.beginListeningForChanges()
            defer { db.stopListeningForChanges() }
            guard !Task.isCancelled else {
                Self.logger.info("event watcher task was canceled after setting up change listening, bailing")
                return
            }
            
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
                
                guard !eventsToSend.isEmpty else {
                    // Nothing to send means nothing can fail, so any rows resolved
                    // this tick are done — clear them from the pending maps.
                    commitPendingSends()
                    continue
                }
                
                do {
                    guard !Task.isCancelled else {
                        Self.logger.info("had \(eventsToSend.count) event(s) to send but event watcher task was canceled, bailing")
                        return
                    }
#if DEBUG
                    Self.logger.debug("sending \(eventsToSend.count) event(s) to PAS")
#endif
                    try await sender(eventsToSend)
                    commitPendingSends()
                } catch {
                    Self.logger.error("couldn't send events to PAS: \(String(reflecting: error)), continuing")
                    try? reportErrorMessage?("imsg event watcher: couldn't send events to PAS: \(String(reflecting: error))")
                    // Leave the resolved rows pending so the next tick retries them.
                }
            }
        } onCancel: { [db] in
            db.stopListeningForChanges()
        }
    }
}
