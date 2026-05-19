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

enum ServerEventPropagation {
    case passThrough
    case consume
}

enum ServerEventWaiterAction {
    case keepWaiting(ServerEventPropagation)
    case finish(ServerEventPropagation)
}

final class EventWatcher {
    static let logger = Logger(imessageLabel: "event-watcher")

    var db: IMDatabase

    /// Tracks the last known state of every chat.
    var chatStates = [String: TimestampedChatState]()
    var updatesCursor: MessageUpdatesCursor

    let currentUserID: String
    let accountID: String
    private var sender: PlatformAPI.EventCallback
    private let reportErrorMessage: PlatformAPI.ReportErrorMessage?
    private let pendingServerEventWaiters = Protected(ServerEventWaiterState())

    init(
        serverEventSender sender: @escaping PlatformAPI.EventCallback,
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

        self.sender = sender
        self.updatesCursor = initialUpdatesCursor
        self.currentUserID = currentUserID
        self.accountID = accountID
        self.reportErrorMessage = reportErrorMessage
    }

    func watchForever() async throws {
        defer { cancelPendingServerEventWaiters() }

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
                try eventsToSend.append(contentsOf: collectMessageUpdateEvents())
            } catch {
                Self.logger.error("couldn't collect event watcher events: \(String(reflecting: error)), continuing")
                try? reportErrorMessage?("imsg event watcher: couldn't collect events: \(String(reflecting: error))")
                continue
            }

            guard !eventsToSend.isEmpty else { continue }

            eventsToSend = await feedPendingServerEventWaiters(eventsToSend)
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

    func registerServerEventWaiter(
        id: UUID,
        handlingEvent handler: @escaping @Sendable (ServerEvent) async throws -> ServerEventWaiterAction
    ) throws {
        let didRegister: Bool
        didRegister = try pendingServerEventWaiters.withLock { state in
            guard !state.isClosed else { return false }
            guard state.waiters[id] == nil else {
                throw ErrorMessage("server event waiter \(id) is already registered")
            }
            state.waiters[id] = ServerEventWaiter(handler: handler)
            return true
        }

        guard didRegister else {
            throw CancellationError()
        }
    }

    func waitForServerEvent(waiterID id: UUID) async throws {
        guard pendingServerEventWaiters.withLock({ $0.waiters[id] != nil }) else {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result = pendingServerEventWaiters.withLock { state -> Result<Void, Error>? in
                    guard var waiter = state.waiters[id] else {
                        return .success(())
                    }
                    guard waiter.continuation == nil else {
                        return .failure(ErrorMessage("server event waiter \(id) is already being awaited"))
                    }

                    waiter.continuation = continuation
                    state.waiters[id] = waiter
                    return nil
                }

                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancelServerEventWaiter(id: id)
        }
    }

    func cancelServerEventWaiter(id: UUID) {
        let waiter = pendingServerEventWaiters.withLock { state in
            state.waiters.removeValue(forKey: id)
        }

        waiter?.continuation?.resume(throwing: CancellationError())
    }

    private func feedPendingServerEventWaiters(_ events: [ServerEvent]) async -> [ServerEvent] {
        var eventsToSend = [ServerEvent]()

        for event in events {
            let waiters = pendingServerEventWaiters.withLock { $0.waiters }
            var consumed = false

            for (id, waiter) in waiters {
                do {
                    let action = try await waiter.handler(event)
                    guard pendingServerEventWaiters.withLock({ $0.waiters[id] != nil }) else {
                        continue
                    }

                    switch action {
                    case let .keepWaiting(propagation):
                        consumed = consumed || propagation == .consume
                    case let .finish(propagation):
                        consumed = consumed || propagation == .consume
                        completeServerEventWaiter(id: id, with: .success(()))
                    }
                } catch {
                    Self.logger.error("server event waiter \(id) failed: \(String(reflecting: error))")
                    try? reportErrorMessage?("imsg event watcher: server event waiter \(id) failed: \(String(reflecting: error))")
                    completeServerEventWaiter(id: id, with: .failure(error))
                }
            }

            if !consumed {
                eventsToSend.append(event)
            }
        }

        return eventsToSend
    }

    private func completeServerEventWaiter(id: UUID, with result: Result<Void, Error>) {
        let waiter = pendingServerEventWaiters.withLock { state in
            state.waiters.removeValue(forKey: id)
        }

        waiter?.continuation?.resume(with: result)
    }

    private func cancelPendingServerEventWaiters() {
        let waiters = pendingServerEventWaiters.withLock { state in
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            state.isClosed = true
            return waiters
        }

        for waiter in waiters {
            waiter.continuation?.resume(throwing: CancellationError())
        }
    }
}

private struct ServerEventWaiter {
    let handler: @Sendable (ServerEvent) async throws -> ServerEventWaiterAction
    var continuation: CheckedContinuation<Void, Error>?
}

private struct ServerEventWaiterState {
    var waiters = [UUID: ServerEventWaiter]()
    var isClosed = false
}
