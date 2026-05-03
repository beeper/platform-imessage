import Foundation
import Logging
import IMessageCore
import PlatformSDK

private let eventWatchingLog = Logger(imessageLabel: "event-watcher-lifecycle")

final class EventWatcherLifecycle {
    static let shared = EventWatcherLifecycle()

    private struct State {
        var onEvent: PlatformAPI.EventCallback?
        var watchingTask: Task<Void, Never>?
        var reportErrorMessage: PlatformAPI.ReportErrorMessage?
        var accountID: String?
    }

    private let state = Protected(State())

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
            state.onEvent = onEvent
            state.reportErrorMessage = reportErrorMessage
            state.accountID = accountID
        }
    }

    func cancelWatchingIfNecessary(clearEventCallback: Bool) async {
        let watchingTask = state.withLock { state in
            let watchingTask = state.watchingTask
            state.watchingTask = nil
            if clearEventCallback {
                state.onEvent = nil
                state.reportErrorMessage = nil
                state.accountID = nil
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

    func startEventWatchingFromCurrentState(lastRowID: Int, lastDateRead: Date) throws {
        guard let onEvent = state.withLock({ $0.onEvent }) else {
            throw ErrorMessage("subscribeToEvents must be called before startEventWatchingFromCurrentState")
        }
        try startWatching(
            onEvent: onEvent,
            lastRowID: lastRowID,
            lastDateRead: lastDateRead,
            source: "current state"
        )
    }

    func startWatching(
        onEvent: @escaping PlatformAPI.EventCallback,
        lastRowID: Int,
        lastDateRead: Date,
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

        eventWatchingLog.debug("starting event watcher from \(source) (last row id: \(lastRowID), last date read: \(lastDateRead))")

        let reportErrorMessage = state.withLock { $0.reportErrorMessage }
        guard let accountID = state.withLock({ $0.accountID }) else {
            throw ErrorMessage("subscribeToEvents must be called before startWatching")
        }

        let eventWatcher = try EventWatcher(
            serverEventSender: { events in
                #if DEBUG
                eventWatchingLog.debug("handing over \(events.count) value(s) to the event callback")
                #endif
                try await onEvent(events)
            },
            initialUpdatesCursor: EventWatcher.MessageUpdatesCursor(lastRowID: lastRowID, lastDateRead: lastDateRead, lastDateEdited: Date()),
            accountID: accountID,
            reportErrorMessage: reportErrorMessage
        )

        let watchingTask = Task {
            eventWatchingLog.debug("going to watch for database changes")
            do {
                try await eventWatcher.watchForever()
            } catch {
                eventWatchingLog.error("event watcher died: \(String(reflecting: error))")
                try? reportErrorMessage?("imsg event watcher died: \(String(reflecting: error))")
            }
        }

        state.withLock { state in
            state.watchingTask = watchingTask
        }
    }
}
