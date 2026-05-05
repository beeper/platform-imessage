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

private enum PendingMessage {
    case reactionAction(
        threadID: PlatformSDK.ThreadID,
        row: MappedMessageRow,
        reaction: AssociatedReaction,
        target: AssociatedMessageTarget,
        previousActionMessageID: PlatformSDK.MessageID?
    )
    case normal(threadID: PlatformSDK.ThreadID, row: MappedMessageRow, change: UpdatedMessageChange)

    var row: MappedMessageRow {
        switch self {
        case let .reactionAction(_, row, _, _, _),
             let .normal(_, row, _):
            return row
        }
    }
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

        var pendingByRowID = OrderedDictionary<Int, PendingMessage>()

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
                        // iMessage only keeps one hidden reaction/removal action row
                        // per participant+target. New reaction rows can point back at
                        // the previous hidden action row so clients can delete it.
                        pendingByRowID[msgRow.rowID] = .reactionAction(
                            threadID: threadID,
                            row: msgRow,
                            reaction: reaction,
                            target: target,
                            previousActionMessageID: previousReactionActionMessageID(
                                replyToGUID: msgRow.replyToGUID,
                                target: target
                            )
                        )
                    }

                    continue
                }

                traceMessageUpdates("message row \(msgRow.rowID) is associated but not a reaction; treating as a message state sync")
            }

            pendingByRowID[msgRow.rowID] = .normal(
                threadID: threadID,
                row: msgRow,
                change: change
            )
        }

        let mappedMessagesByRowID = try PlatformAPI.mapAndHashMessagesByRowID(
            msgRows: pendingByRowID.values.map(\.row),
            attachmentRows: attachmentRows,
            reactionRows: reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )

        var events = [ServerEvent]()
        for pending in pendingByRowID.values {
            let mappedMessages = mappedMessagesByRowID[pending.row.rowID] ?? []
            switch pending {
            case let .reactionAction(threadID, row, reaction, target, previousActionMessageID):
                let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: threadID)
                switch reaction.action {
                case .reacted:
                    let messageReaction = mapMessageReaction(
                        row: row,
                        reaction: reaction,
                        currentUserID: currentUserID,
                        accountID: accountID
                    )
                    events.append(.upsertMessageReactions(
                        threadID: hashedThreadID,
                        messageID: target.messageID,
                        reactions: [PlatformAPI.hashReaction(messageReaction)]
                    ))
                case .unreacted:
                    events.append(.deleteMessageReactions(
                        threadID: hashedThreadID,
                        messageID: target.messageID,
                        ids: [
                            Hasher.participant.tokenizeRemembering(
                                pii: messageSenderID(for: row, currentUserID: currentUserID)
                            ),
                        ]
                    ))
                }
                if !mappedMessages.isEmpty {
                    events.append(.upsertMessages(threadID: hashedThreadID, messages: mappedMessages))
                }
                if let previousActionMessageID {
                    events.append(.deleteMessages(threadID: hashedThreadID, ids: [previousActionMessageID]))
                }
            case let .normal(threadID, _, change):
                let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: threadID)
                if change.isNew, !mappedMessages.isEmpty {
                    events.append(.upsertMessages(threadID: hashedThreadID, messages: mappedMessages))
                }
                guard let kind = MessageUpdateKind(change) else { continue }
                let patches = mappedMessages.compactMap { kind.patch(for: $0) }
                if !patches.isEmpty {
                    events.append(.updateMessages(threadID: hashedThreadID, patches: patches))
                }
            }
        }

        return events
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
