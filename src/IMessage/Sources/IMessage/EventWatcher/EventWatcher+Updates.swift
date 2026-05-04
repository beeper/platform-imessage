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

private enum PendingMessageKind {
    case reactionAdd
    case normal(UpdatedMessageChange)
}

private struct PendingMessage {
    let row: MappedMessageRow
    let kind: PendingMessageKind
}

private struct ThreadBatch {
    let threadID: PlatformSDK.ThreadID
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
        var pendingByThreadID = [PlatformSDK.ThreadID: OrderedDictionary<Int, PendingMessage>]()
        var reactionTargets = Set<ReactionTarget>()

        for change in queryResult.updatedMessages {
            guard let msgRow = msgRowsByRowID[change.rowID] else {
                log.error("message update row \(change.rowID) couldn't be mapped, dropping")
                continue
            }
            let threadID = msgRow.threadID ?? change.chatGUID

            if let associatedGUID = msgRow.associatedMessageGUID?.nonEmpty {
                guard let reaction = reaction(for: msgRow) else {
                    traceMessageUpdates("message row \(msgRow.rowID) is associated but not a reaction; skipping state sync")
                    continue
                }

                if change.isNew {
                    switch reaction.action {
                    case .reacted:
                        pendingByThreadID[threadID, default: [:]][msgRow.rowID] = PendingMessage(row: msgRow, kind: .reactionAdd)
                    case .unreacted:
                        if let replyToGUID = msgRow.replyToGUID {
                            batchesByThreadID[threadID, default: ThreadBatch(threadID: threadID)].deletes.append(replyToGUID)
                        }
                    }
                }

                let target = parseAssociatedMessageTarget(associatedGUID)
                if !target.messageGUID.isEmpty {
                    reactionTargets.insert(ReactionTarget(threadID: threadID, target: target))
                }
                continue
            }

            pendingByThreadID[threadID, default: [:]][msgRow.rowID] = PendingMessage(row: msgRow, kind: .normal(change))
        }

        let allPendingRows = pendingByThreadID.values.flatMap { $0.values.map(\.row) }
        let mappedMessagesByRowID = try mapMessagesByRowID(allPendingRows)

        for (threadID, pendings) in pendingByThreadID {
            var batch = batchesByThreadID[threadID] ?? ThreadBatch(threadID: threadID)
            for pending in pendings.values {
                let mappedMessages = mappedMessagesByRowID[pending.row.rowID] ?? []
                switch pending.kind {
                case .reactionAdd:
                    batch.upserts.append(contentsOf: mappedMessages)
                case .normal(let change):
                    if change.isNew {
                        batch.upserts.append(contentsOf: mappedMessages)
                    }
                    if let kind = MessageUpdateKind(change) {
                        batch.updates.append(contentsOf: mappedMessages.compactMap { kind.patch(for: $0) })
                    }
                }
            }
            batchesByThreadID[threadID] = batch
        }

        // Reaction-target patches are appended AFTER main-loop patches so that
        // `deduplicatedUpdatePatches` (last-write-wins per key) lets the
        // reaction-target's `reactions` field override the `reactions` carried
        // inside a same-batch full-message edit patch. Reordering these two
        // appends will silently corrupt reactions on edited messages.
        for (threadID, patches) in try reactionTargetUpdatePatches(reactionTargets) {
            batchesByThreadID[threadID, default: ThreadBatch(threadID: threadID)].updates.append(contentsOf: patches)
        }

        batchesByThreadID = batchesByThreadID.mapValues { batch in
            var batch = batch
            batch.updates = deduplicatedUpdatePatches(batch.updates)
            return batch
        }

        return stateSyncEvents(batches: batchesByThreadID.values)
    }

    enum MessageUpdateKind {
        case edited, read

        init?(_ change: UpdatedMessageChange) {
            // Edits dominate read receipts: a same-tick edit+read becomes a full-message patch.
            if change.wasEdited { self = .edited }
            else if change.wasRead { self = .read }
            else { return nil }
        }

        func patch(for message: PlatformSDK.Message) -> JSONObject? {
            switch self {
            case .edited:
                return message.jsonObject
            case .read:
                var patch = compactDictionary([
                    "seen": message.seen?.jsonValue,
                    "behavior": message.behavior?.rawValue,
                    "isDelivered": message.isDelivered,
                    "isErrored": message.isErrored,
                ])
                guard !patch.isEmpty else { return nil }
                patch["id"] = message.id
                return patch
            }
        }
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
        let targetMessages = try mapMessagesByRowID(targetRows).values.flatMap { $0 }
        // Same multi-chat de-dup as in messageUpdateEvents: a target row may map to
        // multiple `Message` values via different chat joins; keep first.
        let targetMessagesByID = Dictionary(targetMessages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for target in reactionTargets {
            guard let targetMessage = targetMessagesByID[target.target.messageID] else {
                log.error("reaction target \(target.target.messageGUID) couldn't be mapped, dropping original message update")
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
        guard patches.count > 1 else { return patches }
        // OrderedDictionary preserves first-seen patch order so identical inputs produce
        // identical event sequences; plain `Dictionary` value order is undefined.
        var patchesByID = OrderedDictionary<String, JSONObject>()
        for patch in patches {
            guard let id = patch["id"] as? String else { continue }
            patchesByID[id, default: [:]].merge(patch) { _, new in new }
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
}
