import Foundation
import IMDatabase
import IMessageCore
import PlatformSDK

private let sentMessageLinkWaitTimeout: TimeInterval = 1.5

// Re-query at least this often even without a tick: FSEvents notifications can be
// dropped or coalesced, so a missed tick costs ~1s instead of the full timeout.
private let databaseTickBackstopInterval: TimeInterval = 1.0

enum DatabaseTickWaits {
    typealias SentMessageID = (rowID: Int, guid: String)

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

        while true {
            let changeStream = changes.subscribe()
            let sentMessageIDs = try querySentMessageIDs()
            if sentMessageIDs.count == expectedNewMessageIDCount {
                return sentMessageIDs
            }
            if text != nil, !sentMessageIDs.isEmpty, Date() >= linkDeadline {
                return sentMessageIDs
            }
            if Date() >= timeoutDeadline {
                throw ErrorMessage("timed out waiting for sent messages")
            }

            let wakeDeadline: Date
            if text != nil, !sentMessageIDs.isEmpty {
                wakeDeadline = min(timeoutDeadline, linkDeadline)
            } else {
                wakeDeadline = timeoutDeadline
            }
            _ = try await waitForChange(on: changeStream, until: wakeDeadline, backstopInterval: backstopInterval)
        }
    }

    static func sentThreadIDs(
        timeout: TimeInterval,
        changes: Topic<Void>,
        backstopInterval: TimeInterval = databaseTickBackstopInterval,
        querySentThreadIDs: @escaping @Sendable () throws -> [String?]
    ) async throws -> [String?] {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let changeStream = changes.subscribe()
            let threadIDs = try querySentThreadIDs()
            if !threadIDs.contains(where: { $0 == nil }) || Date() >= deadline {
                return threadIDs
            }

            _ = try await waitForChange(on: changeStream, until: deadline, backstopInterval: backstopInterval)
        }
    }

    static func loadedAttachment(
        messageID: String,
        timeout: TimeInterval,
        changes: Topic<Void>,
        backstopInterval: TimeInterval = databaseTickBackstopInterval,
        loadMessage: @escaping @Sendable () async throws -> PlatformSDK.Message?,
        terminalAttachmentFailureState: @escaping @Sendable () async throws -> Attachment.IMFileTransferState?
    ) async throws -> PlatformSDK.Message {
        let deadline = Date().addingTimeInterval(timeout)
        var isFirstRead = true

        while true {
            let changeStream = changes.subscribe()
            let message = try await loadMessage()
                .orThrow(ErrorMessage("Could not find message \(messageID)"))
            let attachments = message.attachments ?? []
            if isFirstRead {
                guard !attachments.isEmpty else {
                    throw ErrorMessage("Message \(messageID) has no attachments")
                }
                isFirstRead = false
            }
            if !attachments.isEmpty, !attachments.contains(where: { $0.loading == true }) {
                return message
            }

            if let failureState = try await terminalAttachmentFailureState() {
                throw ErrorMessage("Attachment in message \(messageID) failed to load (transfer state: \(failureState.rawValue))")
            }

            guard Date() < deadline else {
                throw ErrorMessage("Timed out waiting for attachment in message \(messageID) to load")
            }

            _ = try await waitForChange(on: changeStream, until: deadline, backstopInterval: backstopInterval)
        }
    }

    private static func waitForChange(on stream: AsyncStream<Void>, until deadline: Date, backstopInterval: TimeInterval) async throws -> Bool {
        let remainingTime = deadline.timeIntervalSinceNow
        guard remainingTime > 0 else { return false }

        let sleepTime = min(remainingTime, backstopInterval)

        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try await Task.sleep(forTimeInterval: sleepTime)
                return false
            }

            do {
                let changed = try await group.next() ?? false
                group.cancelAll()
                return changed
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
