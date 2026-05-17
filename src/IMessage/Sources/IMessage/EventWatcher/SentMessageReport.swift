import Foundation
import IMessageCore
import PlatformSDK

struct SentMessageReport: @unchecked Sendable {
    let rowID: Int
    let threadID: PlatformSDK.ThreadID
    let messages: [PlatformSDK.Message]
}

final class SentMessageReportObservation: @unchecked Sendable {
    let stream: AsyncStream<SentMessageReport>

    private let canceled = Protected(false)
    private let cancelHandler: @Sendable () -> Void

    init(stream: AsyncStream<SentMessageReport>, cancelHandler: @escaping @Sendable () -> Void) {
        self.stream = stream
        self.cancelHandler = cancelHandler
    }

    func cancel() {
        let shouldCancel = canceled.withLock { canceled in
            guard !canceled else { return false }
            canceled = true
            return true
        }
        guard shouldCancel else { return }
        cancelHandler()
    }

    deinit {
        cancel()
    }
}

final class SentMessageReportHub: @unchecked Sendable {
    private struct Observer {
        let minimumRowID: Int
        let continuation: AsyncStream<SentMessageReport>.Continuation
    }

    private let observers = Protected<[UUID: Observer]>([:])

    var observerCount: Int {
        observers.withLock { $0.count }
    }

    func observe(after rowID: Int) -> SentMessageReportObservation {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SentMessageReport.self,
            bufferingPolicy: .unbounded
        )

        continuation.onTermination = { [weak self] _ in
            self?.removeObserver(id)
        }

        observers.withLock { observers in
            observers[id] = Observer(minimumRowID: rowID, continuation: continuation)
        }

        return SentMessageReportObservation(stream: stream) { [weak self] in
            self?.removeObserver(id)
        }
    }

    func broadcast(_ reports: [SentMessageReport]) {
        guard !reports.isEmpty else { return }

        let deliveries = observers.withLock { observers in
            observers.values.map { observer in
                (
                    continuation: observer.continuation,
                    reports: reports.filter { $0.rowID > observer.minimumRowID }
                )
            }
        }

        for delivery in deliveries {
            for report in delivery.reports {
                delivery.continuation.yield(report)
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        let continuation = observers.withLock { observers in
            observers.removeValue(forKey: id)?.continuation
        }
        continuation?.finish()
    }
}
