import Foundation
import IMDatabase
import IMessageCore
import Logging
import PlatformSDK

private let log = Logger(imessageLabel: "event-watcher.updates")

private func traceMessageUpdates(_ message: @autoclosure () -> Logger.Message) {
    guard Defaults.eventWatcherTraceMessageUpdates else { return }
    log.debug(message())
}

private enum ReactionRowKind {
    case add
    case remove
}

private struct ReactionTarget: Hashable {
    var threadID: PlatformSDK.ThreadID
    var messageGUID: String
    var messageID: PlatformSDK.MessageID
}

private let readMessageUpdateKeys = [
    "seen",
    "behavior",
    "isDelivered",
    "isErrored",
]

extension EventWatcher {
    // TODO: Maybe move this type into `IMDatabase` and have methods accept it.
    struct MessageUpdatesCursor {
        let lastRowID: Int
        let lastDateRead: Date
        let lastDateEdited: Date
    }

    func collectMessageUpdateEvents() throws -> [ServerEvent] {
        let previousCursor = updatesCursor
        let queryResult = try db.messages(
            newerThanRowID: previousCursor.lastRowID,
            orReadSince: previousCursor.lastDateRead,
            orEditedSince: previousCursor.lastDateEdited
        )
        traceMessageUpdates("updated messages query returned \(queryResult.updatedMessages.count) updated message(s)")

        defer {
            let newCursor = MessageUpdatesCursor(
                lastRowID: max(queryResult.latestMessageRowID ?? previousCursor.lastRowID, previousCursor.lastRowID),
                lastDateRead: max(queryResult.latestMessageDateRead ?? previousCursor.lastDateRead, previousCursor.lastDateRead),
                lastDateEdited: max(queryResult.latestDateEdited ?? previousCursor.lastDateEdited, previousCursor.lastDateEdited)
            )
            traceMessageUpdates("done computing message state syncs, updating the messages updates cursor to: \(newCursor)")
            updatesCursor = newCursor
        }

        guard !queryResult.updatedMessages.isEmpty else {
            traceMessageUpdates("no messages updated this time around")
            return []
        }

        let msgRows = try db.mappedMessageRows(rowIDs: queryResult.updatedMessages.map(\.rowID))
        let msgRowsByRowID = Dictionary(uniqueKeysWithValues: msgRows.map { ($0.rowID, $0) })

        var upsertsByThreadID = [PlatformSDK.ThreadID: [PlatformSDK.Message]]()
        var updatesByThreadID = [PlatformSDK.ThreadID: [JSONObject]]()
        var deletesByThreadID = [PlatformSDK.ThreadID: [PlatformSDK.MessageID]]()
        var reactionTargets = Set<ReactionTarget>()

        func appendUpserts(_ messages: [PlatformSDK.Message], threadID: PlatformSDK.ThreadID) {
            guard !messages.isEmpty else { return }
            upsertsByThreadID[threadID, default: []].append(contentsOf: messages)
        }

        func appendUpdates(_ patches: [JSONObject], threadID: PlatformSDK.ThreadID) {
            guard !patches.isEmpty else { return }
            updatesByThreadID[threadID, default: []].append(contentsOf: patches)
        }

        for change in queryResult.updatedMessages {
            guard let msgRow = msgRowsByRowID[change.rowID] else {
                log.error("message update row \(change.rowID) couldn't be mapped, dropping")
                continue
            }
            guard let originalThreadID = msgRow.threadID ?? change.chat.guid else {
                log.error("message update row \(change.rowID) didn't have a thread id, dropping")
                continue
            }

            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: originalThreadID)
            let associatedGUID = msgRow.associatedMessageGUID?.nonEmpty

            if let associatedGUID, let reactionKind = reactionRowKind(for: msgRow) {
                if change.isNew {
                    switch reactionKind {
                    case .add:
                        appendUpserts(try mapMessages([msgRow], threadID: originalThreadID), threadID: hashedThreadID)
                    case .remove:
                        if let replyToGUID = msgRow.replyToGUID {
                            deletesByThreadID[hashedThreadID, default: []].append(replyToGUID)
                        }
                    }
                }

                if let target = reactionTarget(threadID: originalThreadID, associatedMessageGUID: associatedGUID) {
                    reactionTargets.insert(target)
                }
                continue
            }

            guard associatedGUID == nil else {
                traceMessageUpdates("message row \(msgRow.rowID) is associated but not a reaction; skipping state sync")
                continue
            }

            let mappedMessages = try mapMessages([msgRow], threadID: originalThreadID)
            if change.isNew {
                appendUpserts(mappedMessages, threadID: hashedThreadID)
            }

            if change.wasEdited || change.wasRead {
                appendUpdates(mappedMessages.compactMap { message in
                    Self.messageUpdatePatch(
                        for: message,
                        wasEdited: change.wasEdited,
                        wasRead: change.wasRead
                    )
                }, threadID: hashedThreadID)
            }
        }

        for target in reactionTargets {
            guard let targetRow = try db.mappedMessageRow(guid: target.messageGUID) else {
                log.error("reaction target \(target.messageGUID) couldn't be mapped, dropping original message update")
                continue
            }

            let targetMessages = try mapMessages([targetRow], threadID: target.threadID)
            guard let targetMessage = targetMessages.first(where: { $0.id == target.messageID }) else {
                log.error("reaction target \(target.messageID) wasn't present in mapped messages, dropping original message update")
                continue
            }

            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: target.threadID)
            appendUpdates([
                [
                    "id": targetMessage.id,
                    "reactions": targetMessage.reactions?.map(\.jsonObject) ?? [],
                ],
            ], threadID: hashedThreadID)
        }

        return stateSyncEvents(
            upsertsByThreadID: upsertsByThreadID,
            updatesByThreadID: deduplicatingUpdatePatches(in: updatesByThreadID),
            deletesByThreadID: deletesByThreadID
        )
    }

    static func messageUpdatePatch(for message: PlatformSDK.Message, wasEdited: Bool, wasRead: Bool) -> JSONObject? {
        let messageObject = message.jsonObject
        if wasEdited {
            return messageObject
        }

        var patch: JSONObject = ["id": message.id]
        if wasRead {
            copy(keys: readMessageUpdateKeys, from: messageObject, to: &patch)
        }

        return patch.count > 1 ? patch : nil
    }

    private static func copy(keys: [String], from messageObject: JSONObject, to patch: inout JSONObject) {
        for key in keys {
            if let value = messageObject[key] {
                patch[key] = value
            }
        }
    }

    private func mapMessages(_ msgRows: [MappedMessageRow], threadID: String) throws -> [PlatformSDK.Message] {
        let payloadRows = try PlatformAPI.messagePayloadRows(db: db, msgRows: msgRows, threadID: threadID)
        return try PlatformAPI.mapAndHashMessages(
            msgRows: msgRows,
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
    }

    private func stateSyncEvents(
        upsertsByThreadID: [PlatformSDK.ThreadID: [PlatformSDK.Message]],
        updatesByThreadID: [PlatformSDK.ThreadID: [JSONObject]],
        deletesByThreadID: [PlatformSDK.ThreadID: [PlatformSDK.MessageID]]
    ) -> [ServerEvent] {
        var events = [ServerEvent]()
        for (threadID, messages) in upsertsByThreadID where !messages.isEmpty {
            events.append(.upsertMessages(threadID: threadID, messages: messages))
        }
        for (threadID, patches) in updatesByThreadID where !patches.isEmpty {
            events.append(.updateMessages(threadID: threadID, patches: patches))
        }
        for (threadID, ids) in deletesByThreadID where !ids.isEmpty {
            events.append(.deleteMessages(threadID: threadID, ids: ids))
        }
        return events
    }

    private func deduplicatingUpdatePatches(in updatesByThreadID: [PlatformSDK.ThreadID: [JSONObject]]) -> [PlatformSDK.ThreadID: [JSONObject]] {
        updatesByThreadID.mapValues { patches in
            var patchesByID = [String: JSONObject]()
            for patch in patches {
                guard let id = patch["id"] as? String else { continue }
                patchesByID[id] = (patchesByID[id] ?? [:]).merging(patch, uniquingKeysWith: { _, new in new })
            }
            return Array(patchesByID.values)
        }
    }

    private func reactionRowKind(for msgRow: MappedMessageRow) -> ReactionRowKind? {
        guard let assocMsgType = associatedMessageTypes[msgRow.associatedMessageType] else {
            return nil
        }
        if assocMsgType.hasPrefix("reacted_") {
            return .add
        }
        if assocMsgType.hasPrefix("unreacted_") {
            return .remove
        }
        return nil
    }

    private func reactionTarget(threadID: String, associatedMessageGUID: String) -> ReactionTarget? {
        let (part, messageGUID) = associatedMessageTarget(associatedMessageGUID)
        guard !messageGUID.isEmpty else { return nil }

        let messageID: String
        if let part, part != "0" {
            messageID = "\(messageGUID)_\(part)"
        } else {
            messageID = messageGUID
        }

        return ReactionTarget(threadID: threadID, messageGUID: messageGUID, messageID: messageID)
    }

    private func associatedMessageTarget(_ associatedMessageGUID: String) -> (part: String?, messageGUID: String) {
        if associatedMessageGUID.hasPrefix("bp:") {
            return (nil, String(associatedMessageGUID.dropFirst(3)))
        }

        let pieces = associatedMessageGUID.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if pieces.count == 2, pieces[0].hasPrefix("p:") {
            let part = String(pieces[0].dropFirst(2))
            var messageGUID = String(pieces[1])
            if messageGUID.hasPrefix("bp:") {
                messageGUID = String(messageGUID.dropFirst(3))
            }
            return (part, messageGUID)
        }

        return (nil, associatedMessageGUID)
    }
}
