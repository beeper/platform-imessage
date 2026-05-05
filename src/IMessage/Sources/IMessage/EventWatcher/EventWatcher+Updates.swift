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
    case reactionAction
    case normal(UpdatedMessageChange)
}

private struct PendingMessage {
    let row: MappedMessageRow
    let kind: PendingMessageKind
}

private struct ThreadBatch {
    var upserts: [PlatformSDK.Message] = []
    var updates: [JSONObject] = []
    var deletes: [PlatformSDK.MessageID] = []
    var reactionUpsertsByMessageID = OrderedDictionary<PlatformSDK.MessageID, [PlatformSDK.MessageReaction]>()
    var reactionDeletesByMessageID = OrderedDictionary<PlatformSDK.MessageID, [PlatformSDK.ID]>()
}

extension EventWatcher {
    static func messageUpdateEvents(
        changes: [UpdatedMessageChange],
        msgRowsByRowID: [Int: MappedMessageRow],
        attachmentRows: [MappedAttachmentRow],
        reactionRows: [MappedReactionMessageRow],
        currentUserID: String,
        accountID: String
    ) throws -> [ServerEvent] {
        guard !changes.isEmpty else {
            traceMessageUpdates("no messages updated this time around")
            return []
        }

        var batchesByThreadID = [PlatformSDK.ThreadID: ThreadBatch]()
        var pendingByThreadID = [PlatformSDK.ThreadID: OrderedDictionary<Int, PendingMessage>]()

        for change in changes {
            guard let msgRow = msgRowsByRowID[change.rowID] else {
                log.error("message update row \(change.rowID) couldn't be mapped, dropping")
                continue
            }
            let threadID = msgRow.threadID ?? change.chatGUID

            if let associatedGUID = msgRow.associatedMessageGUID?.nonEmpty {
                if let reaction = Self.reaction(for: msgRow) {
                    let target = parseAssociatedMessageTarget(associatedGUID)
                    guard !target.messageID.isEmpty else {
                        log.error("message row \(msgRow.rowID) is a reaction but doesn't point at a message, dropping reaction state sync")
                        continue
                    }

                    if change.isNew {
                        var batch = batchesByThreadID[threadID] ?? ThreadBatch()
                        switch reaction.action {
                        case .reacted:
                            let messageReaction = mapMessageReaction(row: msgRow, reaction: reaction, currentUserID: currentUserID, accountID: accountID)
                            batch.reactionUpsertsByMessageID[target.messageID, default: []].append(PlatformAPI.hashReaction(messageReaction))
                        case .unreacted:
                            batch.reactionDeletesByMessageID[target.messageID, default: []].append(
                                Hasher.participant.tokenizeRemembering(pii: messageSenderID(for: msgRow, currentUserID: currentUserID))
                            )
                        }
                        // iMessage only keeps one hidden reaction/removal action row
                        // per participant+target. New reaction rows can point back at
                        // the previous hidden action row so clients can delete it.
                        if let previousActionMessageID = previousReactionActionMessageID(replyToGUID: msgRow.replyToGUID, target: target) {
                            batch.deletes.append(previousActionMessageID)
                        }
                        pendingByThreadID[threadID, default: [:]][msgRow.rowID] = PendingMessage(row: msgRow, kind: .reactionAction)
                        batchesByThreadID[threadID] = batch
                    }

                    continue
                }

                traceMessageUpdates("message row \(msgRow.rowID) is associated but not a reaction; treating as a message state sync")
            }

            pendingByThreadID[threadID, default: [:]][msgRow.rowID] = PendingMessage(row: msgRow, kind: .normal(change))
        }

        let allPendingRows = pendingByThreadID.values.flatMap { $0.values.map(\.row) }
        let mappedMessagesByRowID = try PlatformAPI.mapAndHashMessagesByRowID(
            msgRows: allPendingRows,
            attachmentRows: attachmentRows,
            reactionRows: reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )

        for (threadID, pendings) in pendingByThreadID {
            var batch = batchesByThreadID[threadID] ?? ThreadBatch()
            for pending in pendings.values {
                let mappedMessages = mappedMessagesByRowID[pending.row.rowID] ?? []
                switch pending.kind {
                case .reactionAction:
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
            batch.updates = Self.deduplicatedUpdatePatches(batch.updates)
            batchesByThreadID[threadID] = batch
        }

        return Self.stateSyncEvents(batchesByThreadID)
    }

    func collectMessageUpdateEvents() throws -> [ServerEvent] {
        let previousCursor = updatesCursor
        let queryResult = try db.messages(since: previousCursor)
        traceMessageUpdates("updated messages query returned \(queryResult.updatedMessages.count) updated message(s)")

        let events = try messageUpdateEvents(for: queryResult)
        traceMessageUpdates("done computing message state syncs, updating the messages updates cursor to: \(queryResult.nextCursor)")
        updatesCursor = queryResult.nextCursor
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

        let payloadRows = try PlatformAPI.messagePayloadRows(db: db, msgRows: Array(msgRowsByRowID.values), threadID: "")
        return try Self.messageUpdateEvents(
            changes: queryResult.updatedMessages,
            msgRowsByRowID: msgRowsByRowID,
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
    }

    private enum MessageUpdateKind {
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

    private static func stateSyncEvents(_ batchesByThreadID: [PlatformSDK.ThreadID: ThreadBatch]) -> [ServerEvent] {
        var events = [ServerEvent]()
        // Emit target-message reaction mutations before hidden action message
        // mutations, and keep deletes after upserts so replacement action rows
        // are visible before prior rows disappear.
        for (threadID, batch) in batchesByThreadID {
            guard !batch.upserts.isEmpty ||
                    !batch.updates.isEmpty ||
                    !batch.deletes.isEmpty ||
                    !batch.reactionUpsertsByMessageID.isEmpty ||
                    !batch.reactionDeletesByMessageID.isEmpty else { continue }
            let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: threadID)
            for (messageID, reactions) in batch.reactionUpsertsByMessageID {
                events.append(.upsertMessageReactions(threadID: hashedThreadID, messageID: messageID, reactions: reactions))
            }
            for (messageID, ids) in batch.reactionDeletesByMessageID {
                events.append(.deleteMessageReactions(threadID: hashedThreadID, messageID: messageID, ids: ids))
            }
            if !batch.upserts.isEmpty {
                events.append(.upsertMessages(threadID: hashedThreadID, messages: batch.upserts))
            }
            if !batch.updates.isEmpty {
                events.append(.updateMessages(threadID: hashedThreadID, patches: batch.updates))
            }
            if !batch.deletes.isEmpty {
                events.append(.deleteMessages(threadID: hashedThreadID, ids: batch.deletes))
            }
        }
        return events
    }

    private static func deduplicatedUpdatePatches(_ patches: [JSONObject]) -> [JSONObject] {
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

    private static func reaction(for msgRow: MappedMessageRow) -> AssociatedReaction? {
        guard let associatedMessageType = associatedMessageTypes[msgRow.associatedMessageType],
              case let .reaction(reaction) = associatedMessageType else {
            return nil
        }
        return reaction
    }
}

private func previousReactionActionMessageID(replyToGUID: String?, target: AssociatedMessageTarget) -> PlatformSDK.MessageID? {
    guard let replyToGUID = replyToGUID?.nonEmpty else {
        return nil
    }
    // For fresh reactions, `reply_to_guid` can point at the original target
    // message. Only delete when it points at a prior hidden reaction/removal
    // action row.
    guard replyToGUID != target.messageGUID,
          replyToGUID != target.messageID else {
        return nil
    }
    return replyToGUID
}
