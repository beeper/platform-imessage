import Foundation
import IMDatabase
import Logging

private let log = Logger(swiftServerLabel: "poller.updates")

private func traceMessageUpdates(_ message: @autoclosure () -> Logger.Message) {
    guard Defaults.swiftServer.bool(forKey: DefaultsKeys.pollerTraceMessageUpdates) else { return }
    log.debug(message())
}

private func threadRefreshEvents(forUpdatedChats latest: UpdatedChatsQueryResult) throws -> [PASEvent] {
    guard !latest.updatedChats.isEmpty else { return [] }

    let events: [PASEvent] = latest.updatedChats.compactMap { chat in
        guard let guid = chat.guid else {
            log.error("updated chat didn't have a guid, not vending refresh event")
            return nil
        }
        traceMessageUpdates("chat \(chat) had message updates, queueing a refresh")
        let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: guid)
        return PASEvent.refreshMessagesInThread(id: hashedThreadID)
    }

    return events
}

extension Poller {
    // TODO: Maybe move this type into `IMDatabase` and have methods accept it.
    struct MessageUpdatesCursor {
        let lastRowID: Int
        let lastDateRead: Date
    }

    func pollMessageUpdates() throws -> [PASEvent] {
        let lastRowID = updatesCursor.lastRowID
        let lastDateRead = updatesCursor.lastDateRead

        let queryResult = try db.chats(withMessagesNewerThanRowID: lastRowID, orReadSince: lastDateRead)
        traceMessageUpdates("updated messages query returned \(queryResult.updatedChats.count) updated chat(s)")
        guard !queryResult.updatedChats.isEmpty else {
            traceMessageUpdates("no chats updated this time around")
            return []
        }
        guard let newLastRowID = queryResult.latestMessageRowID else {
            log.error("didn't have new rowid cursor despite having updated chats? skipping updates")
            return []
        }

        defer {
            let newCursor = MessageUpdatesCursor(
                lastRowID: newLastRowID,
                // Inherit the `lastDateRead` if it hasn't changed.
                lastDateRead: queryResult.latestMessageDateRead ?? updatesCursor.lastDateRead
            )
            traceMessageUpdates("done computing refreshes, updating the messages updates cursor to: \(newCursor)")
            updatesCursor = newCursor
        }

        return try threadRefreshEvents(forUpdatedChats: queryResult)
    }
}
