import Foundation
import IMDatabase
import Logging
import IMessageCore
import PlatformSDK

private let eventWatchingLog = Logger(imessageLabel: "event-watcher-lifecycle")

private final class EventWatcherStartSignal: @unchecked Sendable {
    private enum State {
        case pending([CheckedContinuation<Void, any Error>])
        case completed(Result<Void, any Error>)
    }

    private let state = Protected<State>(.pending([]))

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completed = state.withLock { state -> Result<Void, any Error>? in
                switch state {
                case let .pending(continuations):
                    state = .pending(continuations + [continuation])
                    return nil
                case let .completed(result):
                    return result
                }
            }
            if let completed {
                continuation.resume(with: completed)
            }
        }
    }

    func succeed() {
        complete(.success(()))
    }

    func fail(_ error: any Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<Void, any Error>) {
        let continuations = state.withLock { state in
            switch state {
            case let .pending(continuations):
                state = .completed(result)
                return continuations
            case .completed:
                return []
            }
        }
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }
}

final class EventWatcherLifecycle {
    static let shared = EventWatcherLifecycle()

    private struct Subscription {
        var onEvent: PlatformAPI.EventCallback
        var reportErrorMessage: PlatformAPI.ReportErrorMessage?
        var accountID: String
    }

    private struct State {
        var subscription: Subscription?
        var isStarting = false
        var startSignal: EventWatcherStartSignal?
        var watchingTaskID: UUID?
        var watchingTask: Task<Void, Never>?
    }

    private enum StartWatchingDecision {
        case alreadyWatching
        case wait(EventWatcherStartSignal)
        case start(EventWatcherStartSignal)
    }

    private let state = Protected(State())
    private let sentMessageReports = SentMessageReportHub()

    private init() {}

    var isWatching: Bool {
        state.withLock { $0.watchingTask != nil }
    }

    func subscribeToEvents(
        _ onEvent: @escaping PlatformAPI.EventCallback,
        accountID: String,
        reportErrorMessage: PlatformAPI.ReportErrorMessage? = nil
    ) {
        state.withLock { state in
            state.subscription = Subscription(
                onEvent: onEvent,
                reportErrorMessage: reportErrorMessage,
                accountID: accountID
            )
        }
    }

    func cancelWatchingIfNecessary(clearEventCallback: Bool) async {
        let watchingTask = state.withLock { state in
            let watchingTask = state.watchingTask
            state.isStarting = false
            state.startSignal = nil
            state.watchingTaskID = nil
            state.watchingTask = nil
            if clearEventCallback {
                state.subscription = nil
            }
            return watchingTask
        }

        if let watchingTask {
            eventWatchingLog.info("was asked to cancel event watcher task, doing so")
            watchingTask.cancel()
            // Wait for the task to actually finish so callers (e.g. dispose())
            // don't return while the event watcher still holds the DB.
            await watchingTask.value
        } else {
            eventWatchingLog.warning("was asked to cancel event watcher task, but there isn't one; disregarding")
        }
    }

    func observeSentMessages(after rowID: Int) -> SentMessageReportObservation {
        sentMessageReports.observe(after: rowID)
    }

    func startEventWatchingFromCurrentState(
        cursor: MessageUpdatesCursor,
        currentUserID: String,
        accountID: String,
        reportErrorMessage: PlatformAPI.ReportErrorMessage? = nil
    ) async throws {
        try await startWatching(
            initialUpdatesCursor: cursor,
            currentUserID: currentUserID,
            accountID: accountID,
            reportErrorMessage: reportErrorMessage,
            source: "current state"
        )
    }

    private func startWatching(
        initialUpdatesCursor: MessageUpdatesCursor,
        currentUserID: String,
        accountID: String,
        reportErrorMessage: PlatformAPI.ReportErrorMessage?,
        source: String
    ) async throws {
        let newStartSignal = EventWatcherStartSignal()
        let decision = state.withLock { state -> StartWatchingDecision in
            if let startSignal = state.startSignal {
                return .wait(startSignal)
            }
            if state.watchingTask != nil {
                return .alreadyWatching
            }
            state.isStarting = true
            state.startSignal = newStartSignal
            return .start(newStartSignal)
        }

        switch decision {
        case .alreadyWatching:
            eventWatchingLog.debug("was asked to start event watching from \(source), but there was already an event watcher alive; disregarding")
            return
        case let .wait(startSignal):
            eventWatchingLog.debug("was asked to start event watching from \(source), but there was already an event watcher starting; waiting for it")
            try await startSignal.wait()
            return
        case let .start(startSignal):
            try await startWatching(
                startSignal: startSignal,
                initialUpdatesCursor: initialUpdatesCursor,
                currentUserID: currentUserID,
                accountID: accountID,
                reportErrorMessage: reportErrorMessage,
                source: source
            )
        }
    }

    private func startWatching(
        startSignal: EventWatcherStartSignal,
        initialUpdatesCursor: MessageUpdatesCursor,
        currentUserID: String,
        accountID: String,
        reportErrorMessage: PlatformAPI.ReportErrorMessage?,
        source: String
    ) async throws {
        eventWatchingLog.debug("starting event watcher from \(source) with cursor: \(initialUpdatesCursor)")

        let eventWatcher: EventWatcher
        do {
            eventWatcher = try EventWatcher(
                serverEventSender: { events in
                    try await Self.shared.sendServerEvents(events)
                },
                sentMessageReporter: { [sentMessageReports] reports in
                    sentMessageReports.broadcast(reports)
                },
                initialUpdatesCursor: initialUpdatesCursor,
                currentUserID: currentUserID,
                accountID: accountID,
                reportErrorMessage: reportErrorMessage
            )
        } catch {
            startSignal.fail(error)
            clearStartSignal(startSignal)
            throw error
        }

        let watchingTaskID = UUID()
        let watchingTask = Task {
            eventWatchingLog.debug("going to watch for database changes")
            defer {
                Self.shared.clearWatchingTask(id: watchingTaskID)
            }
            do {
                try await eventWatcher.watchForever {
                    startSignal.succeed()
                }
            } catch {
                startSignal.fail(error)
                eventWatchingLog.error("event watcher died: \(String(reflecting: error))")
                try? reportErrorMessage?("imsg event watcher died: \(String(reflecting: error))")
            }
        }

        state.withLock { state in
            state.watchingTaskID = watchingTaskID
            state.watchingTask = watchingTask
        }

        do {
            try await startSignal.wait()
            clearStartSignal(startSignal)
        } catch {
            clearStartSignal(startSignal)
            throw error
        }
    }

    private func sendServerEvents(_ events: [ServerEvent]) async throws {
        guard let subscription = state.withLock({ $0.subscription }) else {
            return
        }
        #if DEBUG
        eventWatchingLog.debug("handing over \(events.count) value(s) to the event callback")
        #endif
        try await subscription.onEvent(events)
    }

    private func clearWatchingTask(id: UUID) {
        state.withLock { state in
            guard state.watchingTaskID == id else { return }
            state.isStarting = false
            state.startSignal = nil
            state.watchingTaskID = nil
            state.watchingTask = nil
        }
    }

    private func clearStartSignal(_ startSignal: EventWatcherStartSignal) {
        state.withLock { state in
            guard state.startSignal === startSignal else { return }
            state.isStarting = false
            state.startSignal = nil
        }
    }
}
