import Foundation
import IMDatabase
import Logging

private let log = Logger(swiftServerLabel: "poller.updates")

private func traceMessageUpdates(_ message: @autoclosure () -> Logger.Message) {
    guard Defaults.pollerTraceMessageUpdates else { return }
    log.debug(message())
}

private func threadRefreshEvents(forChatGUIDs chatGUIDs: [String]) -> [PASEvent] {
    chatGUIDs.map { guid in
        let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: guid)
        return .refreshMessagesInThread(id: hashedThreadID)
    }
}

private func threadRefreshEvents(forUpdatedChats latest: UpdatedChatsQueryResult) -> [PASEvent] {
    threadRefreshEvents(forChatGUIDs: latest.updatedChats.compactMap { chat in
        guard let guid = chat.guid else {
            log.error("updated chat didn't have a guid, not vending refresh event")
            return nil
        }
        traceMessageUpdates("chat \(chat) had message updates, queueing a refresh")
        return guid
    })
}

private func deleteEvents(forDeletedMessages deletedMessages: DeletedMessagesQueryResult) -> (events: [PASEvent], affectedChatGUIDs: Set<String>) {
    var deletedMessageIDsByChatGUID = [String: Set<String>]()

    for deletedMessage in deletedMessages.recoverablyDeletedMessages {
        deletedMessageIDsByChatGUID[deletedMessage.chatGUID, default: []]
            .formUnion(messageDeletionIDs(
                messageGUID: deletedMessage.messageGUID,
                partCount: deletedMessage.partCount,
                hasSubject: deletedMessage.hasSubject
            ))
    }

    for deletedMessage in deletedMessages.removedRecoverableMessages {
        let ids = if let partIndex = deletedMessage.partIndex {
            [messageID(messageGUID: deletedMessage.messageGUID, partIndex: partIndex)]
        } else {
            [deletedMessage.messageGUID]
        }
        deletedMessageIDsByChatGUID[deletedMessage.chatGUID, default: []].formUnion(ids)
    }

    let events = deletedMessageIDsByChatGUID.compactMap { chatGUID, deletedMessageIDs -> PASEvent? in
        guard !deletedMessageIDs.isEmpty else { return nil }
        let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: chatGUID)
        let sortedMessageIDs = deletedMessageIDs.sorted()
        traceMessageUpdates("chat \(chatGUID) had \(sortedMessageIDs.count) deleted message id(s), queueing a state sync delete")
        return .deleteMessages(threadID: hashedThreadID, ids: sortedMessageIDs)
    }

    return (events, Set(deletedMessageIDsByChatGUID.keys))
}

extension Poller {
    // TODO: Maybe move this type into `IMDatabase` and have methods accept it.
    struct MessageUpdatesCursor {
        let lastRowID: Int
        let lastDateRead: Date
        let lastDateEdited: Date
        let lastRecoverableDeleteDate: Date
        let lastRemovedRecoverableMessageRowID: Int
    }

    func pollMessageUpdates() throws -> [PASEvent] {
        let lastRowID = updatesCursor.lastRowID
        let lastDateRead = updatesCursor.lastDateRead

        let updatedChats = try db.chats(withMessagesNewerThanRowID: lastRowID, orReadSince: lastDateRead, orEditedSince: updatesCursor.lastDateEdited)
        traceMessageUpdates("updated messages query returned \(updatedChats.updatedChats.count) updated chat(s)")

        let deletedMessages = try db.deletedMessages(
            sinceRecoverableDeleteDate: updatesCursor.lastRecoverableDeleteDate,
            andRemovedRecoverableRowID: updatesCursor.lastRemovedRecoverableMessageRowID
        )
        traceMessageUpdates(
            "deleted messages query returned \(deletedMessages.recoverablyDeletedMessages.count) recoverable delete(s) and \(deletedMessages.removedRecoverableMessages.count) recoverable removal(s)"
        )

        if !updatedChats.updatedChats.isEmpty, updatedChats.latestMessageRowID == nil {
            log.error("didn't have new rowid cursor despite having updated chats? keeping the old cursor")
        }

        defer {
            let newCursor = MessageUpdatesCursor(
                lastRowID: updatedChats.latestMessageRowID ?? updatesCursor.lastRowID,
                // Inherit the `lastDateRead` if it hasn't changed.
                lastDateRead: updatedChats.latestMessageDateRead ?? updatesCursor.lastDateRead,
                lastDateEdited: updatedChats.latestDateEdited ?? updatesCursor.lastDateEdited,
                lastRecoverableDeleteDate: deletedMessages.latestRecoverableDeleteDate ?? updatesCursor.lastRecoverableDeleteDate,
                lastRemovedRecoverableMessageRowID: deletedMessages.latestRemovedRecoverableMessageRowID ?? updatesCursor.lastRemovedRecoverableMessageRowID
            )
            traceMessageUpdates("done computing refreshes, updating the messages updates cursor to: \(newCursor)")
            updatesCursor = newCursor
        }

        let deletedMessageEvents = deleteEvents(forDeletedMessages: deletedMessages)
        let refreshChatGUIDs = Set(updatedChats.updatedChats.compactMap(\.guid))
            .union(deletedMessageEvents.affectedChatGUIDs)

        guard !refreshChatGUIDs.isEmpty || !deletedMessageEvents.events.isEmpty else {
            traceMessageUpdates("no message or delete updates this time around")
            return []
        }

        var events = deletedMessageEvents.events
        events.append(contentsOf: threadRefreshEvents(forUpdatedChats: updatedChats))
        events.append(contentsOf: threadRefreshEvents(forChatGUIDs: Array(
            deletedMessageEvents.affectedChatGUIDs.subtracting(Set(updatedChats.updatedChats.compactMap(\.guid)))
        )))
        return events
    }
}
