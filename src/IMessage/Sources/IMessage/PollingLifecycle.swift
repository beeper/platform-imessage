import Foundation
import Logging
import IMessageCore
import PlatformSDK

private let pollingLog = Logger(imessageLabel: "polling-lifecycle")
typealias PollingEventSender = @Sendable ([ServerEvent]) async throws -> Void

final class PollingLifecycle {
    static let shared = PollingLifecycle()

    private struct State {
        var onEvent: PollingEventSender?
        var pollingTask: Task<Void, Never>?
        var reportToSentry: Poller.ReportToSentry?
    }

    private let state = Protected(State())

    private init() {}

    func setEventCallback(_ onEvent: @escaping PollingEventSender, reportToSentry: Poller.ReportToSentry? = nil) {
        state.withLock { state in
            state.onEvent = onEvent
            state.reportToSentry = reportToSentry
        }
    }

    func cancelPollingIfNecessary(clearEventCallback: Bool) async {
        let pollingTask = state.withLock { state in
            let pollingTask = state.pollingTask
            state.pollingTask = nil
            if clearEventCallback {
                state.onEvent = nil
                state.reportToSentry = nil
            }
            return pollingTask
        }

        if let pollingTask {
            pollingLog.info("was asked to cancel polling task, doing so")
            pollingTask.cancel()
            // Wait for the task to actually finish so callers (e.g. dispose())
            // don't return while the poller still holds the DB.
            await pollingTask.value
        } else {
            pollingLog.warning("was asked to cancel polling task, but there isn't one; disregarding")
        }
    }

    func startPollingFromCurrentState(lastRowID: Int, lastDateRead: Date) throws {
        guard let onEvent = state.withLock({ $0.onEvent }) else {
            throw ErrorMessage("subscribeToEvents must be called before startEventPollingFromCurrentState")
        }
        try startPolling(
            onEvent: onEvent,
            lastRowID: lastRowID,
            lastDateRead: lastDateRead,
            source: "current state"
        )
    }

    func startPolling(
        onEvent: @escaping PollingEventSender,
        lastRowID: Int,
        lastDateRead: Date,
        source: String
    ) throws {
        let existingTask = state.withLock { state in
            let task = state.pollingTask
            state.pollingTask = nil
            return task
        }
        if let existingTask {
            pollingLog.warning("was asked to start polling from \(source), but there was already a poller alive; canceling it before proceeding")
            existingTask.cancel()
        }

        pollingLog.debug("starting poller from \(source) (last row id: \(lastRowID), last date read: \(lastDateRead))")

        let reportToSentry = state.withLock { $0.reportToSentry }

        let poller = try Poller(
            serverEventSender: { events in
                #if DEBUG
                pollingLog.debug("handing over \(events.count) value(s) to the event callback")
                #endif
                try await onEvent(events)
            },
            initialUpdatesCursor: Poller.MessageUpdatesCursor(lastRowID: lastRowID, lastDateRead: lastDateRead, lastDateEdited: Date()),
            reportToSentry: reportToSentry
        )

        let pollingTask = Task {
            pollingLog.debug("going to poll forever")
            do {
                try await poller.pollForever()
            } catch {
                pollingLog.error("poller died: \(String(reflecting: error))")
                reportToSentry?("imsg poller died: \(String(reflecting: error))")
            }
        }

        state.withLock { state in
            state.pollingTask = pollingTask
        }
    }
}
