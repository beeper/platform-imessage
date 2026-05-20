import Combine
import Foundation
import IMDatabase
import Logging
import IMessageCore
import PlatformSDK

private let eventWatchingLog = Logger(imessageLabel: "event-watcher-lifecycle")

final class EventWatcherLifecycle {
    static let shared = EventWatcherLifecycle()

    var eventPublisher: AnyPublisher<[ServerEvent], Never> {
        eventSubject.eraseToAnyPublisher()
    }

    private let eventSubject = PassthroughSubject<[ServerEvent], Never>()
    private let state: Protected<State> = Protected(State())

    private init() {}

    var isWatching: Bool {
        state.withLock { $0.watchingTask != nil }
    }

    func subscribeToEvents(
        _ onEvent: @escaping PlatformAPI.EventCallback,
        reportErrorMessage: PlatformAPI.ReportErrorMessage? = nil
    ) {
        let listener = EventListener(
            onEvent: onEvent,
            reportErrorMessage: reportErrorMessage
        )
        let cancellable = eventPublisher.sink { [listener] events in
            listener.send(events)
        }

        state.withLock { state in
            state.listeners[UUID()] = ListenerRegistration(
                listener: listener,
                cancellable: cancellable
            )
        }
    }

    func cancelWatchingIfNecessary(clearEventCallback: Bool) async {
        let watchingTask = state.withLock { state in
            let watchingTask = state.watchingTask
            state.watchingTask = nil
            if clearEventCallback {
                state.cancelListeners()
            }
            return watchingTask
        }

        if let watchingTask {
            eventWatchingLog.info("was asked to cancel event watcher task, doing so")
            watchingTask.cancel()
            // Wait for the task to actually finish so callers (e.g. dispose())
            // don't return while the event watcher still holds the DB.
            await watchingTask.value
        } else if clearEventCallback {
            eventWatchingLog.debug("was asked to clear event callbacks; no event watcher task was running")
        } else {
            eventWatchingLog.warning("was asked to cancel event watcher task, but there isn't one; disregarding")
        }
    }

    func startEventWatchingFromCurrentState(
        cursor: MessageUpdatesCursor,
        currentUserID: String,
        accountID: String,
        reportErrorMessage: PlatformAPI.ReportErrorMessage? = nil
    ) throws {
        try startWatching(
            initialUpdatesCursor: cursor,
            currentUserID: currentUserID,
            accountID: accountID,
            reportErrorMessage: reportErrorMessage,
            source: "current state"
        )
    }

    func sendEvents(_ events: [ServerEvent]) async throws {
        guard !events.isEmpty else { return }
        eventSubject.send(events)
    }

    private func startWatching(
        initialUpdatesCursor: MessageUpdatesCursor,
        currentUserID: String,
        accountID: String,
        reportErrorMessage: PlatformAPI.ReportErrorMessage?,
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
            initialUpdatesCursor: initialUpdatesCursor,
            currentUserID: currentUserID,
            accountID: accountID,
            reportErrorMessage: reportErrorMessage
        )
        let eventForwarder = UncheckedSendableBox(
            eventWatcher.events.sink { [eventSubject] events in
                eventSubject.send(events)
            }
        )

        let watchingTask = Task { [eventForwarder] in
            defer { eventForwarder.value.cancel() }
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

extension EventWatcherLifecycle {
    private final class EventListener: @unchecked Sendable {
        private let onEvent: PlatformAPI.EventCallback
        private let reportErrorMessage: PlatformAPI.ReportErrorMessage?
        private let pendingTask = Protected<Task<Void, Never>?>(nil)

        init(
            onEvent: @escaping PlatformAPI.EventCallback,
            reportErrorMessage: PlatformAPI.ReportErrorMessage?
        ) {
            self.onEvent = onEvent
            self.reportErrorMessage = reportErrorMessage
        }

        func send(_ events: [ServerEvent]) {
            pendingTask.withLock { previousTask in
                let task = Task { [onEvent, reportErrorMessage, previousTask] in
                    await previousTask?.value
                    guard !Task.isCancelled else { return }

                    do {
                        #if DEBUG
                        eventWatchingLog.debug("handing over \(events.count) value(s) to an event callback")
                        #endif
                        try await onEvent(events)
                    } catch {
                        eventWatchingLog.error("event callback failed: \(String(reflecting: error))")
                        try? reportErrorMessage?("imsg event callback failed: \(String(reflecting: error))")
                    }
                }
                previousTask = task
            }
        }

        func cancel() {
            pendingTask.withLock { task in
                task?.cancel()
                task = nil
            }
        }
    }

    private struct ListenerRegistration {
        var listener: EventListener
        var cancellable: AnyCancellable
    }

    private struct State {
        var listeners: [UUID: ListenerRegistration] = [:]
        var watchingTask: Task<Void, Never>?

        mutating func cancelListeners() {
            for listener in listeners.values {
                listener.listener.cancel()
                listener.cancellable.cancel()
            }
            listeners.removeAll()
        }
    }
}
