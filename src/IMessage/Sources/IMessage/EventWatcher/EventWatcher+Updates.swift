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

private struct ReactionTarget: Hashable {
    var threadID: PlatformSDK.ThreadID
    var target: AssociatedMessageTarget
}

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

        let events = try messageUpdateEvents(for: queryResult)
        let newCursor = MessageUpdatesCursor(
            lastRowID: max(queryResult.latestMessageRowID ?? previousCursor.lastRowID, previousCursor.lastRowID),
            lastDateRead: max(queryResult.latestMessageDateRead ?? previousCursor.lastDateRead, previousCursor.lastDateRead),
            lastDateEdited: max(queryResult.latestDateEdited ?? previousCursor.lastDateEdited, previousCursor.lastDateEdited)
        )
        traceMessageUpdates("done computing message state syncs, updating the messages updates cursor to: \(newCursor)")
        updatesCursor = newCursor
        return events
    }

    private func messageUpdateEvents(for queryResult: UpdatedMessagesQueryResult) throws -> [ServerEvent] {
        guard !queryResult.updatedMessages.isEmpty else {
            traceMessageUpdates("no messages updated this time around")
            return []
        }

        let msgRows = try queryResult.updatedMessages
            .map(\.rowID)
            .chunked(into: maxMessageUpdateRowFetchBatchSize)
            .flatMap { try db.mappedMessageRows(rowIDs: Array($0)) }
        let msgRowsByRowID = Dictionary(uniqueKeysWithValues: msgRows.map { ($0.rowID, $0) })

        var rowsToMapByThreadID = [PlatformSDK.ThreadID: [MappedMessageRow]]()
        var scheduledRowIDsByThreadID = [PlatformSDK.ThreadID: Set<Int>]()
        var normalChangesByRowID = [Int: UpdatedMessageChange]()
        var reactionAddRowIDs = Set<Int>()
        var hashedThreadIDs = [PlatformSDK.ThreadID: PlatformSDK.ThreadID]()
        var updatesByThreadID = [PlatformSDK.ThreadID: [JSONObject]]()
        var deletesByThreadID = [PlatformSDK.ThreadID: [PlatformSDK.MessageID]]()
        var reactionTargets = Set<ReactionTarget>()

        func hashedThreadID(for originalThreadID: PlatformSDK.ThreadID) -> PlatformSDK.ThreadID {
            if let hashedThreadID = hashedThreadIDs[originalThreadID] {
                return hashedThreadID
            }
            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: originalThreadID)
            hashedThreadIDs[originalThreadID] = hashedThreadID
            return hashedThreadID
        }

        func scheduleMapping(_ msgRow: MappedMessageRow, threadID originalThreadID: PlatformSDK.ThreadID) {
            if scheduledRowIDsByThreadID[originalThreadID, default: []].insert(msgRow.rowID).inserted {
                rowsToMapByThreadID[originalThreadID, default: []].append(msgRow)
            }
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

            let associatedGUID = msgRow.associatedMessageGUID?.nonEmpty

            if let associatedGUID, let reactionAction = reactionAction(for: msgRow) {
                if change.isNew {
                    switch reactionAction {
                    case .reacted:
                        scheduleMapping(msgRow, threadID: originalThreadID)
                        reactionAddRowIDs.insert(msgRow.rowID)
                    case .unreacted:
                        if let replyToGUID = msgRow.replyToGUID {
                            // Delete the hidden added-reaction message.
                            deletesByThreadID[hashedThreadID(for: originalThreadID), default: []].append(replyToGUID)
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

            scheduleMapping(msgRow, threadID: originalThreadID)
            normalChangesByRowID[msgRow.rowID] = change
        }

        var upsertsByThreadID = [PlatformSDK.ThreadID: [PlatformSDK.Message]]()
        for (originalThreadID, rows) in rowsToMapByThreadID {
            let mappedMessagesByRowID = try mapMessagesByRowID(rows, threadID: originalThreadID)
            let hashedThreadID = hashedThreadID(for: originalThreadID)
            for row in rows {
                let mappedMessages = mappedMessagesByRowID[row.rowID] ?? []
                if reactionAddRowIDs.contains(row.rowID) {
                    upsertsByThreadID[hashedThreadID, default: []].append(contentsOf: mappedMessages)
                }
                if let change = normalChangesByRowID[row.rowID] {
                    if change.isNew {
                        upsertsByThreadID[hashedThreadID, default: []].append(contentsOf: mappedMessages)
                    }

                    if change.wasEdited || change.wasRead {
                        updatesByThreadID[hashedThreadID, default: []].append(
                            contentsOf: mappedMessages.compactMap { message in
                                Self.messageUpdatePatch(
                                    for: message,
                                    wasEdited: change.wasEdited,
                                    wasRead: change.wasRead
                                )
                            }
                        )
                    }
                }
            }
        }

        for (threadID, patches) in try reactionTargetUpdatePatches(reactionTargets) {
            updatesByThreadID[hashedThreadID(for: threadID), default: []].append(contentsOf: patches)
        }

        return stateSyncEvents(
            upsertsByThreadID: upsertsByThreadID,
            updatesByThreadID: deduplicatingUpdatePatches(in: updatesByThreadID),
            deletesByThreadID: deletesByThreadID
        )
    }

    static func messageUpdatePatch(for message: PlatformSDK.Message, wasEdited: Bool, wasRead: Bool) -> JSONObject? {
        if wasEdited {
            return message.jsonObject
        }

        guard wasRead else {
            return nil
        }

        var patch: JSONObject = ["id": message.id]
        patch["seen"] = message.seen?.jsonValue
        patch["behavior"] = message.behavior?.rawValue
        patch["isDelivered"] = message.isDelivered
        patch["isErrored"] = message.isErrored
        return patch.count > 1 ? patch : nil
    }

    private func reactionTargetUpdatePatches(
        _ reactionTargets: Set<ReactionTarget>
    ) throws -> [PlatformSDK.ThreadID: [JSONObject]] {
        var patchesByThreadID = [PlatformSDK.ThreadID: [JSONObject]]()
        for (threadID, targets) in Dictionary(grouping: reactionTargets, by: \.threadID) {
            let targetGUIDs = Array(Set(targets.map { $0.target.messageGUID }))
            let targetRows = try targetGUIDs
                .chunked(into: maxMessageUpdateRowFetchBatchSize)
                .flatMap { try db.mappedMessageRows(guids: Array($0)) }
            let targetRowsByGUID = Dictionary(uniqueKeysWithValues: targetRows.map { ($0.guid, $0) })
            let targetMessages = try mapMessagesByRowID(targetRows, threadID: threadID).values.flatMap { $0 }
            let targetMessagesByID = Dictionary(uniqueKeysWithValues: targetMessages.map { ($0.id, $0) })

            for target in targets {
                guard targetRowsByGUID[target.target.messageGUID] != nil else {
                    log.error("reaction target \(target.target.messageGUID) couldn't be mapped, dropping original message update")
                    continue
                }
                guard let targetMessage = targetMessagesByID[target.target.messageID] else {
                    log.error("reaction target \(target.target.messageID) wasn't present in mapped messages, dropping original message update")
                    continue
                }

                patchesByThreadID[threadID, default: []].append([
                    "id": targetMessage.id,
                    "reactions": targetMessage.reactions?.map(\.jsonObject) ?? [],
                ])
            }
        }
        return patchesByThreadID
    }

    private func mapMessagesByRowID(
        _ msgRows: [MappedMessageRow],
        threadID: PlatformSDK.ThreadID
    ) throws -> [Int: [PlatformSDK.Message]] {
        try PlatformAPI.mapAndHashMessagesByRowID(
            db: db,
            msgRows: msgRows,
            threadID: threadID,
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

    private func reactionAction(for msgRow: MappedMessageRow) -> ReactionAction? {
        guard let assocMsgType = associatedMessageTypes[msgRow.associatedMessageType],
              let parts = reactionParts(assocMsgType) else {
            return nil
        }
        return parts.action
    }

    private func reactionTarget(threadID: PlatformSDK.ThreadID, associatedMessageGUID: String) -> ReactionTarget? {
        let target = parseAssociatedMessageTarget(associatedMessageGUID)
        guard !target.messageGUID.isEmpty else { return nil }
        return ReactionTarget(threadID: threadID, target: target)
    }
}

private let maxMessageUpdateRowFetchBatchSize = 500

private extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: startIndex, to: endIndex, by: size).map { start in
            self[start ..< Swift.min(start + size, endIndex)]
        }
    }
}
