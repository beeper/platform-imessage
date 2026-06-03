import Foundation
import IMDatabase
import IMessageCore
import PlatformSDK

private let sentMessageLinkWaitTimeout: TimeInterval = 1.5

// Re-query at least this often even without a tick: FSEvents notifications can be
// dropped or coalesced, so a missed tick costs ~1s instead of the full timeout.
private let databaseTickBackstopInterval: TimeInterval = 1.0
private let loadedAttachmentMinimumRequeryInterval: TimeInterval = 0.25

// todo: DatabaseTickWaits.{sentMessageIDs,sentThreadIDs} shouldn't exist, we get ServerEvents for new messages, use that
enum DatabaseTickWaits {
    typealias SentMessageID = (rowID: Int, guid: String)

    private enum WaitResult<T> {
        case finished(T)
        case waitingUntil(Date)
    }

    static func sentMessageIDs(
        text: String?,
        timeout: TimeInterval,
        changes: Topic<Void>,
        linkTimeout: TimeInterval = sentMessageLinkWaitTimeout,
        backstopInterval: TimeInterval = databaseTickBackstopInterval,
        querySentMessageIDs: @escaping @Sendable () throws -> [SentMessageID]
    ) async throws -> [SentMessageID] {
        let startedAt = Date()
        let timeoutDeadline = startedAt.addingTimeInterval(timeout)
        let linkDeadline = startedAt.addingTimeInterval(linkTimeout)
        let expectedNewMessageIDCount = text.map { max($0.linkCount, 1) } ?? 1

        return try await waitForDatabaseResult(
            changes: changes,
            backstopInterval: backstopInterval,
            query: {
                try querySentMessageIDs()
            },
            evaluate: { sentMessageIDs in
                let now = Date()
                if sentMessageIDs.count == expectedNewMessageIDCount {
                    return .finished(sentMessageIDs)
                }
                if text != nil, !sentMessageIDs.isEmpty, now >= linkDeadline {
                    return .finished(sentMessageIDs)
                }
                if now >= timeoutDeadline {
                    throw ErrorMessage("timed out waiting for sent messages")
                }

                let wakeDeadline: Date
                if text != nil, !sentMessageIDs.isEmpty {
                    wakeDeadline = min(timeoutDeadline, linkDeadline)
                } else {
                    wakeDeadline = timeoutDeadline
                }
                return .waitingUntil(wakeDeadline)
            }
        )
    }

    static func sentThreadIDs(
        timeout: TimeInterval,
        changes: Topic<Void>,
        backstopInterval: TimeInterval = databaseTickBackstopInterval,
        querySentThreadIDs: @escaping @Sendable () throws -> [String?]
    ) async throws -> [String?] {
        let deadline = Date().addingTimeInterval(timeout)

        return try await waitForDatabaseResult(
            changes: changes,
            backstopInterval: backstopInterval,
            query: {
                try querySentThreadIDs()
            },
            evaluate: { threadIDs in
                if !threadIDs.contains(nil) || Date() >= deadline {
                    return .finished(threadIDs)
                }
                return .waitingUntil(deadline)
            }
        )
    }

    static func loadedAttachment(
        messageID: String,
        timeout: TimeInterval,
        changes: Topic<Void>,
        backstopInterval: TimeInterval = databaseTickBackstopInterval,
        minimumRequeryInterval: TimeInterval = loadedAttachmentMinimumRequeryInterval,
        loadMessage: @escaping @Sendable () async throws -> PlatformSDK.Message?,
        terminalAttachmentFailureState: @escaping @Sendable () async throws -> Attachment.IMFileTransferState?
    ) async throws -> PlatformSDK.Message {
        let deadline = Date().addingTimeInterval(timeout)
        var isFirstRead = true

        return try await waitForDatabaseResult(
            changes: changes,
            backstopInterval: backstopInterval,
            minimumRequeryInterval: minimumRequeryInterval,
            query: {
                try await loadMessage()
                    .orThrow(ErrorMessage("Could not find message \(messageID)"))
            },
            evaluate: { message in
                let attachments = message.attachments ?? []
                if isFirstRead {
                    guard !attachments.isEmpty else {
                        throw ErrorMessage("Message \(messageID) has no attachments")
                    }
                    isFirstRead = false
                }
                if !attachments.isEmpty, !attachments.contains(where: { $0.loading == true }) {
                    return .finished(message)
                }

                if let failureState = try await terminalAttachmentFailureState() {
                    throw ErrorMessage("Attachment in message \(messageID) failed to load (transfer state: \(failureState.rawValue))")
                }

                guard Date() < deadline else {
                    throw ErrorMessage("Timed out waiting for attachment in message \(messageID) to load")
                }

                return .waitingUntil(deadline)
            }
        )
    }

    private static func waitForDatabaseResult<T>(
        changes: Topic<Void>,
        backstopInterval: TimeInterval,
        minimumRequeryInterval: TimeInterval = 0,
        query: @escaping @Sendable () async throws -> T,
        evaluate: (T) async throws -> WaitResult<T>
    ) async throws -> T {
        while true {
            let changeStream = changes.subscribe()
            let result = try await query()
            switch try await evaluate(result) {
            case let .finished(value):
                return value
            case let .waitingUntil(deadline):
                let earliestNextQuery = Date().addingTimeInterval(minimumRequeryInterval)
                try await waitForChange(on: changeStream, until: deadline, backstopInterval: backstopInterval)
                try await waitUntil(earliestNextQuery, cappedAt: deadline)
            }
        }
    }

    private static func waitForChange(on stream: AsyncStream<Void>, until deadline: Date, backstopInterval: TimeInterval) async throws {
        let remainingTime = deadline.timeIntervalSinceNow
        guard remainingTime > 0 else { return }

        let sleepTime = min(remainingTime, backstopInterval)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            group.addTask {
                try await Task.sleep(forTimeInterval: sleepTime)
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static func waitUntil(_ date: Date, cappedAt deadline: Date) async throws {
        let sleepUntil = min(date, deadline)
        let remainingTime = sleepUntil.timeIntervalSinceNow
        guard remainingTime > 0 else { return }
        try await Task.sleep(forTimeInterval: remainingTime)
    }
}
