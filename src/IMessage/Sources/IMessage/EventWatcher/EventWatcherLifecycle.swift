import Foundation
import IMDatabase
import Logging
import IMessageCore
import PlatformSDK

private let eventWatchingLog = Logger(imessageLabel: "event-watcher-lifecycle")

final class EventWatcherLifecycle {
    static let shared = EventWatcherLifecycle()

    private let state: Protected<State> = Protected(State())

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

    func startEventWatchingFromCurrentState(cursor: MessageUpdatesCursor, currentUserID: String) throws {
        guard let subscription = state.withLock({ $0.subscription }) else {
            throw ErrorMessage("subscribeToEvents must be called before startEventWatchingFromCurrentState")
        }
        try startWatching(
            subscription: subscription,
            initialUpdatesCursor: cursor,
            currentUserID: currentUserID,
            source: "current state"
        )
    }

    func sendEvents(_ events: [ServerEvent]) async throws {
        guard !events.isEmpty else { return }
        guard let subscription = state.withLock({ $0.subscription }) else {
            eventWatchingLog.warning("dropping \(events.count) event(s); no event callback is subscribed")
            return
        }

        try await subscription.onEvent(events)
    }

    private func startWatching(
        subscription: Subscription,
        initialUpdatesCursor: MessageUpdatesCursor,
        currentUserID: String,
        source: String
    ) throws {
        let existingTask = state.withLock { state in
            let task = state.watchingTask
            state.watchingTask = nil
            return task
        }
        if let existingTask {
            eventWatchingLog.warning("was asked to start event watching from \(source), but there was already an event watcher alive; canceling it before proceeding")
            existingTask.cancel()
        }

        eventWatchingLog.debug("starting event watcher from \(source) with cursor: \(initialUpdatesCursor)")

        let eventWatcher = try EventWatcher(
            serverEventSender: { events in
                #if DEBUG
                eventWatchingLog.debug("handing over \(events.count) value(s) to the event callback")
                #endif
                try await subscription.onEvent(events)
            },
            initialUpdatesCursor: initialUpdatesCursor,
            currentUserID: currentUserID,
            accountID: subscription.accountID,
            reportErrorMessage: subscription.reportErrorMessage
        )

        let watchingTask = Task {
            eventWatchingLog.debug("going to watch for database changes")
            do {
                try await eventWatcher.watchForever()
            } catch {
                eventWatchingLog.error("event watcher died: \(String(reflecting: error))")
                try? subscription.reportErrorMessage?("imsg event watcher died: \(String(reflecting: error))")
            }
        }

        state.withLock { state in
            state.watchingTask = watchingTask
        }
    }
}

extension EventWatcherLifecycle {
    private struct Subscription {
        var onEvent: PlatformAPI.EventCallback
        var reportErrorMessage: PlatformAPI.ReportErrorMessage?
        var accountID: String
    }

    private struct State {
        var subscription: Subscription?
        var watchingTask: Task<Void, Never>?
    }
}
