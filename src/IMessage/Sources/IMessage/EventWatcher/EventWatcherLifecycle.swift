import Foundation
import Logging
import IMessageCore
import PlatformSDK

private let eventWatchingLog = Logger(imessageLabel: "event-watcher-lifecycle")
typealias EventWatcherEventSender = @Sendable ([ServerEvent]) async throws -> Void

final class EventWatcherLifecycle {
    static let shared = EventWatcherLifecycle()

    private struct State {
        var onEvent: EventWatcherEventSender?
        var watchingTask: Task<Void, Never>?
        var reportToSentry: EventWatcher.ReportToSentry?
    }

    private let state = Protected(State())

    private init() {}

    var isWatching: Bool {
        state.withLock { $0.watchingTask != nil }
    }

    func setEventCallback(_ onEvent: @escaping EventWatcherEventSender, reportToSentry: EventWatcher.ReportToSentry? = nil) {
        state.withLock { state in
            state.onEvent = onEvent
            state.reportToSentry = reportToSentry
        }
    }

    func cancelWatchingIfNecessary(clearEventCallback: Bool) async {
        let watchingTask = state.withLock { state in
            let watchingTask = state.watchingTask
            state.watchingTask = nil
            if clearEventCallback {
                state.onEvent = nil
                state.reportToSentry = nil
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
        onEvent: @escaping EventWatcherEventSender,
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

        let reportToSentry = state.withLock { $0.reportToSentry }

        let eventWatcher = try EventWatcher(
            serverEventSender: { events in
                #if DEBUG
                eventWatchingLog.debug("handing over \(events.count) value(s) to the event callback")
                #endif
                try await onEvent(events)
            },
            initialUpdatesCursor: EventWatcher.MessageUpdatesCursor(lastRowID: lastRowID, lastDateRead: lastDateRead, lastDateEdited: Date()),
            reportToSentry: reportToSentry
        )

        let watchingTask = Task {
            eventWatchingLog.debug("going to watch for database changes")
            do {
                try await eventWatcher.watchForever()
            } catch {
                eventWatchingLog.error("event watcher died: \(String(reflecting: error))")
                reportToSentry?("imsg event watcher died: \(String(reflecting: error))")
            }
        }

        state.withLock { state in
            state.watchingTask = watchingTask
        }
    }
}
