import Combine
import Foundation
import IMDatabase
import IMessageCore
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

final class EventWatcher {
    static let logger = Logger(imessageLabel: "event-watcher")

    var db: IMDatabase

    /// Tracks the last known state of every chat.
    var chatStates = [String: TimestampedChatState]()
    var updatesCursor: MessageUpdatesCursor

    let currentUserID: String
    let accountID: String
    let events = PassthroughSubject<[ServerEvent], Never>()
    private let reportErrorMessage: PlatformAPI.ReportErrorMessage?
    private let changeHandlingQueue = DispatchQueue(label: "imessage.event-watcher.changes")
    private let stopped = Protected(false)
    private var changeSubscription: AnyCancellable?

    init(
        initialUpdatesCursor: MessageUpdatesCursor,
        currentUserID: String,
        accountID: String,
        reportErrorMessage: PlatformAPI.ReportErrorMessage? = nil
    ) throws {
        self.db = try IMDatabase()

        if Defaults.eventWatcherTraceChangeListening {
            Self.logger.debug("tracing change listening, telling IMDatabase to be noisy")
            self.db.noisy = true
        }

        self.updatesCursor = initialUpdatesCursor
        self.currentUserID = currentUserID
        self.accountID = accountID
        self.reportErrorMessage = reportErrorMessage
    }

    func watchForever() async throws {
        stopped.withLock { $0 = false }
        defer {
            stopped.withLock { $0 = true }
            changeSubscription?.cancel()
            changeSubscription = nil
            events.send(completion: .finished)
        }

        chatStates = try db.chatStates().mapValues(TimestampedChatState.init)
        try db.beginListeningForChanges()

        changeSubscription = db.changes.publisher
            .receive(on: changeHandlingQueue)
            .sink { [weak self] in
                self?.handleDatabaseChange()
            }

        do {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: UInt64.max)
            }
        } catch is CancellationError {
            Self.logger.debug("event watcher task was canceled, bailing")
        }
    }

    private func handleDatabaseChange() {
        guard !stopped.read() else {
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
            try eventsToSend.append(contentsOf: collectMessageUpdateEvents())
        } catch {
            Self.logger.error("couldn't collect event watcher events: \(String(reflecting: error)), continuing")
            try? reportErrorMessage?("imsg event watcher: couldn't collect events: \(String(reflecting: error))")
            return
        }

        guard !eventsToSend.isEmpty else { return }

        guard !stopped.read() else {
            Self.logger.info("had \(eventsToSend.count) event(s) to send but event watcher task was canceled, bailing")
            return
        }
        #if DEBUG
        Self.logger.debug("publishing \(eventsToSend.count) event(s)")
        #endif
        events.send(eventsToSend)
    }
}
