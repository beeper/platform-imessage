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
    var reactionUpsertsByMessageID = OrderedDictionary<PlatformSDK.MessageID, [PlatformSDK.MessageReaction]>()
    var reactionDeletesByMessageID = OrderedDictionary<PlatformSDK.MessageID, [PlatformSDK.ID]>()
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

        for change in queryResult.updatedMessages {
            guard let msgRow = msgRowsByRowID[change.rowID] else {
                log.error("message update row \(change.rowID) couldn't be mapped, dropping")
                continue
            }
            let threadID = msgRow.threadID ?? change.chatGUID

            if let associatedGUID = msgRow.associatedMessageGUID?.nonEmpty {
                if let reaction = reaction(for: msgRow) {
                    let target = parseAssociatedMessageTarget(associatedGUID)
                    guard !target.messageID.isEmpty else {
                        log.error("message row \(msgRow.rowID) is a reaction but doesn't point at a message, dropping reaction state sync")
                        continue
                    }

                    if change.isNew {
                        var batch = batchesByThreadID[threadID] ?? ThreadBatch(threadID: threadID)
                        switch reaction.action {
                        case .reacted:
                            if let messageReaction = mapMessageReaction(row: msgRow, reaction: reaction, currentUserID: currentUserID, accountID: accountID) {
                                batch.reactionUpsertsByMessageID[target.messageID, default: []].append(PlatformAPI.hashReaction(messageReaction))
                            } else {
                                log.error("message row \(msgRow.rowID) is a reaction but couldn't be mapped, dropping reaction state sync")
                            }
                            pendingByThreadID[threadID, default: [:]][msgRow.rowID] = PendingMessage(row: msgRow, kind: .reactionAdd)
                        case .unreacted:
                            batch.reactionDeletesByMessageID[target.messageID, default: []].append(
                                PlatformAPI.hashedParticipantID(messageSenderID(for: msgRow, currentUserID: currentUserID))
                            )
                            if let replyToGUID = msgRow.replyToGUID {
                                batch.deletes.append(replyToGUID)
                            }
                        }
                        batchesByThreadID[threadID] = batch
                    }

                    continue
                }

                traceMessageUpdates("message row \(msgRow.rowID) is associated but not a reaction; treating as a message state sync")
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

        for threadID in batchesByThreadID.keys {
            guard var batch = batchesByThreadID[threadID], batch.updates.count > 1 else { continue }
            batch.updates = deduplicatedUpdatePatches(batch.updates)
            batchesByThreadID[threadID] = batch
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
        // Per-thread emit order keeps creates before updates and deletes after
        // both; reaction events are scoped to their target message via
        // objectIDs.messageID.
        for batch in batches {
            guard !batch.upserts.isEmpty ||
                    !batch.updates.isEmpty ||
                    !batch.deletes.isEmpty ||
                    !batch.reactionUpsertsByMessageID.isEmpty ||
                    !batch.reactionDeletesByMessageID.isEmpty else { continue }
            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: batch.threadID)
            for (messageID, reactions) in batch.reactionUpsertsByMessageID where !reactions.isEmpty {
                events.append(.upsertMessageReactions(threadID: hashedThreadID, messageID: messageID, reactions: reactions))
            }
            if !batch.upserts.isEmpty {
                events.append(.upsertMessages(threadID: hashedThreadID, messages: batch.upserts))
            }
            if !batch.updates.isEmpty {
                events.append(.updateMessages(threadID: hashedThreadID, patches: batch.updates))
            }
            for (messageID, ids) in batch.reactionDeletesByMessageID where !ids.isEmpty {
                events.append(.deleteMessageReactions(threadID: hashedThreadID, messageID: messageID, ids: ids))
            }
            if !batch.deletes.isEmpty {
                events.append(.deleteMessages(threadID: hashedThreadID, ids: batch.deletes))
            }
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
