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
    /// Number of database-change ticks between forced full unread-state passes.
    /// The interval bounds the staleness of deletion reconciliation and chat-only
    /// read-state changes that the scoped per-tick pass cannot observe.
    private static let fullUnreadStatePassInterval = 50

    /// Upper bound on `affectedChatGUIDs` for a scoped unread-state pass before
    /// we promote to a full pass. SQLite's default `SQLITE_MAX_VARIABLE_NUMBER`
    /// is 999; 500 leaves comfortable headroom for the rest of the binds in
    /// `chatStates(forChatGUIDs:)` while still avoiding the cost of a full
    /// pass for typical workloads.
    private static let maxScopedChatGUIDs = 500

    var db: IMDatabase

    /// Tracks the last known state of every chat.
    var chatStates = [String: TimestampedChatState]()
    var updatesCursor: MessageUpdatesCursor
    private var databaseChangesSinceFullUnreadStatePass = 0

    let currentUserID: String
    let accountID: String
    private var sender: PlatformAPI.EventCallback
    private let reportErrorMessage: PlatformAPI.ReportErrorMessage?

    init(
        serverEventSender sender: @escaping PlatformAPI.EventCallback,
        initialUpdatesCursor: MessageUpdatesCursor,
        currentUserID: String,
        accountID: String,
        reportErrorMessage: PlatformAPI.ReportErrorMessage? = nil
    ) throws {
        self.db = try IMDatabase()
        if Defaults.eventWatcherTraceChangeListening {
            log.debug("tracing change listening, telling IMDatabase to be noisy")
            self.db.noisy = true
        }
        self.sender = sender
        self.updatesCursor = initialUpdatesCursor
        self.currentUserID = currentUserID
        self.accountID = accountID
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
                let messageUpdateBatch = try collectMessageUpdateBatch()

                // Force a full pass whenever the scoped pass cannot observe the
                // change we care about:
                //   1. No affected chats at all (chat-only updates / deletions).
                //   2. Every affected chat is already tracked as read — the
                //      scoped pass would emit nothing yet still miss chat-only
                //      `last_read_message_timestamp` changes elsewhere. The full
                //      pass is cheap relative to the bug it avoids.
                //   3. Affected-chat count exceeds the scoped-pass parameter
                //      ceiling (see `maxScopedChatGUIDs`).
                let affectedChatsAlreadyRead = !messageUpdateBatch.changedChatGUIDs.isEmpty
                    && messageUpdateBatch.changedChatGUIDs.allSatisfy { (chatStates[$0]?.state.unreadCount ?? 0) == 0 }
                let forceFullUnreadStatePass = shouldForceFullUnreadStatePass(
                    forceNow: messageUpdateBatch.changedChatGUIDs.isEmpty
                        || affectedChatsAlreadyRead
                        || messageUpdateBatch.changedChatGUIDs.count > Self.maxScopedChatGUIDs
                )

                // Cheaply detect chats that vanished from the iMessage DB since
                // the last tick so we can emit `deleteThreads` events without
                // paying for a full unread-states pass.
                let currentlyExistingGUIDs = try db.chatGUIDsWithMessages()
                let perTickDeletedGUIDs = Array(Set(chatStates.keys).subtracting(currentlyExistingGUIDs))

                // Query unread states for the chats touched by message updates.
                // Per-tick deletion reconciliation happens above via
                // `chatGUIDsWithMessages()`; the periodic full pass is now a
                // backstop for chat-only read-state changes that scoped passes
                // cannot observe.
                try eventsToSend.append(
                    contentsOf: diffChatStates(
                        affectedChatGUIDs: messageUpdateBatch.changedChatGUIDs,
                        deletedChatGUIDs: perTickDeletedGUIDs,
                        forceFullUnreadStatePass: forceFullUnreadStatePass
                    )
                )

                // Ditto, but for any new messages/read state changes.
                eventsToSend.append(contentsOf: messageUpdateBatch.events)
                updatesCursor = messageUpdateBatch.nextCursor
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
                try? reportErrorMessage?("imsg event watcher: couldn't send events to PAS: \(String(reflecting: error))")
            }
        }
    }

    func shouldForceFullUnreadStatePass(forceNow: Bool) -> Bool {
        let decision = Self.nextPassDecision(
            currentCount: databaseChangesSinceFullUnreadStatePass,
            forceNow: forceNow,
            interval: Self.fullUnreadStatePassInterval
        )
        databaseChangesSinceFullUnreadStatePass = decision.newCount
        return decision.force
    }

    /// Pure decision function for the periodic-full-pass counter. Increments
    /// the tick counter and decides whether this tick should be promoted to a
    /// full unread-state pass (either because `forceNow` was requested, or
    /// because the counter reached `interval`). Resets the counter to 0
    /// whenever a full pass fires.
    static func nextPassDecision(
        currentCount: Int,
        forceNow: Bool,
        interval: Int
    ) -> (force: Bool, newCount: Int) {
        let incremented = currentCount + 1
        if forceNow || incremented >= interval {
            return (force: true, newCount: 0)
        }
        return (force: false, newCount: incremented)
    }
}
