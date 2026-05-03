import Collections
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

private struct ThreadBatch {
    let threadID: PlatformSDK.ThreadID
    var rowsToMapByRowID = OrderedDictionary<Int, MappedMessageRow>()
    var upserts: [PlatformSDK.Message] = []
    var updates: [JSONObject] = []
    var deletes: [PlatformSDK.MessageID] = []
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

        let msgRows = try db.mappedMessageRows(rowIDs: queryResult.updatedMessages.map(\.rowID))
        // `messageJoins` LEFT JOINs `chat_message_join`, so a message in multiple
        // chats yields multiple rows with the same ROWID. Keep first.
        let msgRowsByRowID = Dictionary(msgRows.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })

        var batchesByThreadID = [PlatformSDK.ThreadID: ThreadBatch]()
        var normalChangesByRowID = [Int: UpdatedMessageChange]()
        var reactionAddRowIDs = Set<Int>()
        var reactionTargets = Set<ReactionTarget>()

        for change in queryResult.updatedMessages {
            guard let msgRow = msgRowsByRowID[change.rowID] else {
                log.error("message update row \(change.rowID) couldn't be mapped, dropping")
                continue
            }
            let threadID = msgRow.threadID ?? change.chatGUID

            let associatedGUID = msgRow.associatedMessageGUID?.nonEmpty

            if let associatedGUID, let reaction = reaction(for: msgRow) {
                if change.isNew {
                    switch reaction.action {
                    case .reacted:
                        batchesByThreadID[threadID, default: ThreadBatch(threadID: threadID)].rowsToMapByRowID[msgRow.rowID] = msgRow
                        reactionAddRowIDs.insert(msgRow.rowID)
                    case .unreacted:
                        if let replyToGUID = msgRow.replyToGUID {
                            // Delete the hidden added-reaction message.
                            batchesByThreadID[threadID, default: ThreadBatch(threadID: threadID)].deletes.append(replyToGUID)
                        }
                    }
                }

                if let target = reactionTarget(threadID: threadID, associatedMessageGUID: associatedGUID) {
                    reactionTargets.insert(target)
                }
                continue
            }

            guard associatedGUID == nil else {
                traceMessageUpdates("message row \(msgRow.rowID) is associated but not a reaction; skipping state sync")
                continue
            }

            batchesByThreadID[threadID, default: ThreadBatch(threadID: threadID)].rowsToMapByRowID[msgRow.rowID] = msgRow
            normalChangesByRowID[msgRow.rowID] = change
        }

        let mappedMessagesByRowID = try mapMessagesByRowID(batchesByThreadID.values.flatMap(\.rowsToMapByRowID.values))
        for threadID in batchesByThreadID.keys {
            for row in batchesByThreadID[threadID]!.rowsToMapByRowID.values {
                let mappedMessages = mappedMessagesByRowID[row.rowID] ?? []
                if reactionAddRowIDs.contains(row.rowID) {
                    batchesByThreadID[threadID]!.upserts.append(contentsOf: mappedMessages)
                }
                if let change = normalChangesByRowID[row.rowID] {
                    if change.isNew {
                        batchesByThreadID[threadID]!.upserts.append(contentsOf: mappedMessages)
                    }

                    if change.wasEdited || change.wasRead {
                        batchesByThreadID[threadID]!.updates.append(
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

        // Reaction-target patches are appended AFTER main-loop patches so that
        // `deduplicatedUpdatePatches` (last-write-wins per key) lets the
        // reaction-target's `reactions` field override the `reactions` carried
        // inside a same-batch full-message edit patch. Reordering these two
        // appends will silently corrupt reactions on edited messages.
        for (threadID, patches) in try reactionTargetUpdatePatches(reactionTargets) {
            batchesByThreadID[threadID, default: ThreadBatch(threadID: threadID)].updates.append(contentsOf: patches)
        }

        for threadID in batchesByThreadID.keys {
            batchesByThreadID[threadID]!.updates = deduplicatedUpdatePatches(batchesByThreadID[threadID]!.updates)
        }

        return stateSyncEvents(batches: batchesByThreadID.values)
    }

    static func messageUpdatePatch(for message: PlatformSDK.Message, wasEdited: Bool, wasRead: Bool) -> JSONObject? {
        if wasEdited {
            return message.jsonObject
        }

        guard wasRead else {
            return nil
        }

        let patch = compactDictionary([
            "id": message.id,
            "seen": message.seen?.jsonValue,
            "behavior": message.behavior?.rawValue,
            "isDelivered": message.isDelivered,
            "isErrored": message.isErrored,
        ])
        return patch.count > 1 ? patch : nil
    }

    private func reactionTargetUpdatePatches(
        _ reactionTargets: Set<ReactionTarget>
    ) throws -> [PlatformSDK.ThreadID: [JSONObject]] {
        guard !reactionTargets.isEmpty else {
            return [:]
        }

        var patchesByThreadID = [PlatformSDK.ThreadID: [JSONObject]]()
        let targetGUIDs = Array(Set(reactionTargets.map { $0.target.messageGUID }))
        let targetRows = try db.mappedMessageRows(guids: targetGUIDs)
        let targetRowGUIDs = Set(targetRows.map(\.guid))
        let targetMessages = try mapMessagesByRowID(targetRows).values.flatMap { $0 }
        // Same multi-chat de-dup as in messageUpdateEvents: a target row may map to
        // multiple `Message` values via different chat joins; keep first.
        let targetMessagesByID = Dictionary(targetMessages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for target in reactionTargets {
            guard targetRowGUIDs.contains(target.target.messageGUID) else {
                log.error("reaction target \(target.target.messageGUID) couldn't be mapped, dropping original message update")
                continue
            }
            guard let targetMessage = targetMessagesByID[target.target.messageID] else {
                log.error("reaction target \(target.target.messageID) wasn't present in mapped messages, dropping original message update")
                continue
            }

            patchesByThreadID[target.threadID, default: []].append([
                "id": targetMessage.id,
                "reactions": targetMessage.reactions?.map(\.jsonObject) ?? [],
            ])
        }
        return patchesByThreadID
    }

    private func mapMessagesByRowID(_ msgRows: [MappedMessageRow]) throws -> [Int: [PlatformSDK.Message]] {
        try PlatformAPI.mapAndHashMessagesByRowID(
            db: db,
            msgRows: msgRows,
            threadID: "",
            currentUserID: currentUserID,
            accountID: accountID
        )
    }

    private func stateSyncEvents(batches: Dictionary<PlatformSDK.ThreadID, ThreadBatch>.Values) -> [ServerEvent] {
        var events = [ServerEvent]()
        for batch in batches where !batch.upserts.isEmpty {
            events.append(.upsertMessages(threadID: Hasher.thread.tokenizeRemembering(pii: batch.threadID), messages: batch.upserts))
        }
        for batch in batches where !batch.updates.isEmpty {
            events.append(.updateMessages(threadID: Hasher.thread.tokenizeRemembering(pii: batch.threadID), patches: batch.updates))
        }
        for batch in batches where !batch.deletes.isEmpty {
            events.append(.deleteMessages(threadID: Hasher.thread.tokenizeRemembering(pii: batch.threadID), ids: batch.deletes))
        }
        return events
    }

    private func deduplicatedUpdatePatches(_ patches: [JSONObject]) -> [JSONObject] {
        var patchesByID = [String: JSONObject]()
        for patch in patches {
            guard let id = patch["id"] as? String else { continue }
            patchesByID[id] = (patchesByID[id] ?? [:]).merging(patch, uniquingKeysWith: { _, new in new })
        }
        return Array(patchesByID.values)
    }

    private func reaction(for msgRow: MappedMessageRow) -> AssociatedReaction? {
        guard let associatedMessageType = associatedMessageTypes[msgRow.associatedMessageType],
              case let .reaction(reaction) = associatedMessageType else {
            return nil
        }
        return reaction
    }

    private func reactionTarget(threadID: PlatformSDK.ThreadID, associatedMessageGUID: String) -> ReactionTarget? {
        let target = parseAssociatedMessageTarget(associatedMessageGUID)
        guard !target.messageGUID.isEmpty else { return nil }
        return ReactionTarget(threadID: threadID, target: target)
    }
}
