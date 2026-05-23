import Collections
import Foundation
import IMDatabase
import IMessageCore
import Logging
import PlatformSDK

private let log = Logger(imessageLabel: "event-watcher.updates")
private let pendingChatJoinTimeout: TimeInterval = 3
private let pendingLinkPreviewTimeout: TimeInterval = 2 * 60

private func traceMessageUpdates(_ message: @autoclosure () -> Logger.Message) {
    guard Defaults.eventWatcherTraceMessageUpdates else { return }
    log.debug(message())
}

private enum PendingMessage {
    case reactionAction(
            threadID: PlatformSDK.ThreadID,
            row: MappedMessageRow,
            reaction: AssociatedReaction,
            target: AssociatedMessageTarget
         )
    case normal(threadID: PlatformSDK.ThreadID, row: MappedMessageRow, change: UpdatedMessageChange)

    var row: MappedMessageRow {
        switch self {
        case let .reactionAction(_, row, _, _),
             let .normal(_, row, _):
            return row
        }
    }
}

private struct MessageUpdateEventContext {
    let events: [ServerEvent]
    let messageRowsByRowID: [Int: MappedMessageRow]
    let mappedMessagesByRowID: [Int: [PlatformSDK.Message]]
}

extension EventWatcher {
    static func messageUpdateEvents(
        changes: [UpdatedMessageChange],
        messageRowsByRowID: [Int: MappedMessageRow],
        attachmentRows: [MappedAttachmentRow],
        reactionRows: [MappedReactionMessageRow],
        currentUserID: String,
        accountID: String
    ) throws -> [ServerEvent] {
        try messageUpdateEventContext(
            changes: changes,
            messageRowsByRowID: messageRowsByRowID,
            attachmentRows: attachmentRows,
            reactionRows: reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        ).events
    }

    private static func messageUpdateEventContext(
        changes: [UpdatedMessageChange],
        messageRowsByRowID: [Int: MappedMessageRow],
        attachmentRows: [MappedAttachmentRow],
        reactionRows: [MappedReactionMessageRow],
        currentUserID: String,
        accountID: String
    ) throws -> MessageUpdateEventContext {
        guard !changes.isEmpty else {
            traceMessageUpdates("no messages updated this time around")
            return MessageUpdateEventContext(events: [], messageRowsByRowID: messageRowsByRowID, mappedMessagesByRowID: [:])
        }

        let changes = mergedChangesByRowID(changes)
        var pendingByRowID = OrderedDictionary<Int, PendingMessage>()

        for change in changes {
            guard let messageRow = messageRowsByRowID[change.rowID] else {
                log.error("message update row \(change.rowID) couldn't be mapped, dropping")
                continue
            }
            let threadID = messageRow.threadID ?? change.chatGUID

            if let associatedGUID = messageRow.associatedMessageGUID?.nonEmpty {
                if let reaction = Self.reaction(for: messageRow) {
                    let target = parseAssociatedMessageTarget(associatedGUID)
                    guard !target.messageID.isEmpty else {
                        log.error("message row \(messageRow.rowID) is a reaction but doesn't point at a message, dropping reaction state sync")
                        continue
                    }

                    if change.isNew {
                        pendingByRowID[messageRow.rowID] = .reactionAction(
                            threadID: threadID,
                            row: messageRow,
                            reaction: reaction,
                            target: target
                        )
                    }

                    continue
                }

                traceMessageUpdates("message row \(messageRow.rowID) is associated but not a reaction; treating as a message state sync")
            }

            pendingByRowID[messageRow.rowID] = .normal(
                threadID: threadID,
                row: messageRow,
                change: change
            )
        }

        let mappedMessagesByRowID = try PlatformAPI.mapAndHashMessagesByRowID(
            messageRows: pendingByRowID.values.map(\.row),
            attachmentRows: attachmentRows,
            reactionRows: reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )

        var events = [ServerEvent]()
        for pending in pendingByRowID.values {
            let mappedMessages = mappedMessagesByRowID[pending.row.rowID] ?? []
            switch pending {
            case let .reactionAction(threadID, row, reaction, target):
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
                    let participantID = Hasher.participant.tokenizeRemembering(
                        pii: messageSenderID(for: row, currentUserID: currentUserID)
                    )
                    let reactionKey = reaction.platformReactionKey(emoji: row.associatedMessageEmoji) ?? ""
                    events.append(.deleteMessageReactions(
                        threadID: hashedThreadID,
                        messageID: target.messageID,
                        ids: [messageReactionID(participantID: participantID, reactionKey: reactionKey)]
                    ))
                }
                if !mappedMessages.isEmpty {
                    events.append(.upsertMessages(threadID: hashedThreadID, messages: mappedMessages))
                }
            case let .normal(threadID, _, change):
                let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: threadID)
                if change.isNew {
                    if !mappedMessages.isEmpty {
                        events.append(.upsertMessages(threadID: hashedThreadID, messages: mappedMessages))
                    }
                    continue
                }
                guard let kind = MessageUpdateKind(change) else { continue }
                let patches = mappedMessages.compactMap { kind.patch(for: $0) }
                if !patches.isEmpty {
                    events.append(.updateMessages(threadID: hashedThreadID, patches: patches))
                }
            }
        }

        return MessageUpdateEventContext(
            events: events,
            messageRowsByRowID: messageRowsByRowID,
            mappedMessagesByRowID: mappedMessagesByRowID
        )
    }

    func collectMessageUpdateEvents() async throws -> [ServerEvent] {
        let previousCursor = updatesCursor
        let queryResult = try db.messages(since: previousCursor)
        traceMessageUpdates(
            "updated messages query returned \(queryResult.updatedMessages.count) updated message(s) and \(queryResult.unresolvedNewMessageRowIDs.count) unresolved new message(s)"
        )

        var changes = try resolvePendingNewMessageChanges()
        let previewChanges = try resolvePendingLinkPreviewChanges()
        rememberPendingNewMessages(rowIDs: queryResult.unresolvedNewMessageRowIDs)

        changes.append(contentsOf: queryResult.updatedMessages)
        changes.append(contentsOf: previewChanges)

        let events = try messageUpdateEvents(for: changes)
        traceMessageUpdates("done computing message state syncs, updating the messages updates cursor to: \(queryResult.nextCursor)")
        updatesCursor = queryResult.nextCursor
        return events
    }

    private func messageUpdateEvents(for changes: [UpdatedMessageChange]) throws -> [ServerEvent] {
        guard !changes.isEmpty else {
            traceMessageUpdates("no messages updated this time around")
            return []
        }

        let changes = Self.mergedChangesByRowID(changes)
        let messageRows = try db.mappedMessageRows(rowIDs: changes.map(\.rowID))
        // `messageJoins` LEFT JOINs `chat_message_join`, so a message in multiple
        // chats yields multiple rows with the same ROWID. Keep first.
        let messageRowsByRowID = Dictionary(messageRows.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })

        let payloadRows = try PlatformAPI.messagePayloadRows(db: db, messageRows: Array(messageRowsByRowID.values), threadID: "")
        let context = try Self.messageUpdateEventContext(
            changes: changes,
            messageRowsByRowID: messageRowsByRowID,
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
        trackPendingLinkPreviewCandidates(
            changes: changes,
            messageRowsByRowID: context.messageRowsByRowID,
            mappedMessagesByRowID: context.mappedMessagesByRowID
        )
        return context.events
    }

    private enum MessageUpdateKind {
        case full, read

        init?(_ change: UpdatedMessageChange) {
            // Full patches dominate read receipts: a same-tick edit/preview+read
            // replaces stale merged message state in one update event.
            if change.wasEdited || change.isPreviewUpdate {
                self = .full
            } else if change.wasRead {
                self = .read
            } else {
                return nil
            }
        }

        func patch(for message: PlatformSDK.Message) -> JSONObject? {
            switch self {
            case .full:
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

    private static func reaction(for messageRow: MappedMessageRow) -> AssociatedReaction? {
        guard let associatedMessageType = associatedMessageTypes[messageRow.associatedMessageType],
              case let .reaction(reaction) = associatedMessageType else {
            return nil
        }
        return reaction
    }

    private static func mergedChangesByRowID(_ changes: [UpdatedMessageChange]) -> [UpdatedMessageChange] {
        var changesByRowID = OrderedDictionary<Int, UpdatedMessageChange>()
        for change in changes {
            if let existing = changesByRowID[change.rowID] {
                changesByRowID[change.rowID] = existing.merging(change)
            } else {
                changesByRowID[change.rowID] = change
            }
        }
        return Array(changesByRowID.values)
    }

    private func rememberPendingNewMessages(rowIDs: [Int]) {
        let now = Date()
        for rowID in rowIDs where pendingUnresolvedNewMessageRowIDs[rowID] == nil {
            pendingUnresolvedNewMessageRowIDs[rowID] = now
        }
    }

    private func resolvePendingNewMessageChanges() throws -> [UpdatedMessageChange] {
        guard !pendingUnresolvedNewMessageRowIDs.isEmpty else {
            return []
        }

        let now = Date()
        var resolvedChanges: [UpdatedMessageChange] = []
        var rowIDsToRemove: [Int] = []

        for (rowID, firstSeen) in pendingUnresolvedNewMessageRowIDs {
            if let chatGUID = try db.threadIDForMessage(rowID: rowID) {
                resolvedChanges.append(UpdatedMessageChange(
                    rowID: rowID,
                    chatGUID: chatGUID,
                    isNew: true,
                    wasRead: false,
                    wasEdited: false
                ))
                rowIDsToRemove.append(rowID)
                continue
            }

            if now.timeIntervalSince(firstSeen) >= pendingChatJoinTimeout {
                log.error("couldn't join message \(rowID) to chat after deferred ticks, dropping")
                rowIDsToRemove.append(rowID)
            }
        }

        for rowID in rowIDsToRemove {
            pendingUnresolvedNewMessageRowIDs.removeValue(forKey: rowID)
        }

        return resolvedChanges
    }

    private func resolvePendingLinkPreviewChanges() throws -> [UpdatedMessageChange] {
        guard !pendingLinkPreviewCandidates.isEmpty else {
            return []
        }

        expirePendingLinkPreviewCandidates()
        guard !pendingLinkPreviewCandidates.isEmpty else {
            return []
        }

        let rowIDs = Array(pendingLinkPreviewCandidates.keys)
        let messageRows = try db.mappedMessageRows(rowIDs: rowIDs)
        let messageRowsByRowID = Dictionary(messageRows.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
        let missingRowIDs = rowIDs.filter { messageRowsByRowID[$0] == nil }
        for rowID in missingRowIDs {
            pendingLinkPreviewCandidates.removeValue(forKey: rowID)
        }

        guard !messageRowsByRowID.isEmpty else {
            return []
        }

        let payloadRows = try PlatformAPI.messagePayloadRows(db: db, messageRows: Array(messageRowsByRowID.values), threadID: "")
        let mappedMessagesByRowID = try PlatformAPI.mapAndHashMessagesByRowID(
            messageRows: Array(messageRowsByRowID.values),
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )

        var changes: [UpdatedMessageChange] = []
        for rowID in rowIDs {
            guard let candidate = pendingLinkPreviewCandidates[rowID],
                  let row = messageRowsByRowID[rowID],
                  Self.mappedMessagesContainPreview(mappedMessagesByRowID[rowID] ?? []) else {
                continue
            }

            changes.append(UpdatedMessageChange(
                rowID: rowID,
                chatGUID: row.threadID ?? candidate.chatGUID,
                isNew: false,
                wasRead: false,
                wasEdited: false,
                isPreviewUpdate: true
            ))
            pendingLinkPreviewCandidates.removeValue(forKey: rowID)
        }

        return changes
    }

    private func expirePendingLinkPreviewCandidates() {
        let now = Date()
        let expiredRowIDs = pendingLinkPreviewCandidates.compactMap { element -> Int? in
            let (rowID, candidate) = element
            return now.timeIntervalSince(candidate.firstSeen) >= pendingLinkPreviewTimeout ? rowID : nil
        }
        for rowID in expiredRowIDs {
            pendingLinkPreviewCandidates.removeValue(forKey: rowID)
        }
    }

    private func trackPendingLinkPreviewCandidates(
        changes: [UpdatedMessageChange],
        messageRowsByRowID: [Int: MappedMessageRow],
        mappedMessagesByRowID: [Int: [PlatformSDK.Message]]
    ) {
        let now = Date()
        for change in changes where change.isNew {
            guard let row = messageRowsByRowID[change.rowID],
                  row.isFromMe == 1,
                  row.balloonBundleID == BalloonBundleKind.url.rawValue else {
                continue
            }

            if Self.mappedMessagesContainPreview(mappedMessagesByRowID[row.rowID] ?? []) {
                pendingLinkPreviewCandidates.removeValue(forKey: row.rowID)
                continue
            }

            if pendingLinkPreviewCandidates[row.rowID] == nil {
                pendingLinkPreviewCandidates[row.rowID] = PendingLinkPreviewCandidate(
                    firstSeen: now,
                    chatGUID: row.threadID ?? change.chatGUID
                )
            }
        }
    }

    private static func mappedMessagesContainPreview(_ messages: [PlatformSDK.Message]) -> Bool {
        messages.contains { message in
            message.links?.isEmpty == false
                || message.tweets?.isEmpty == false
                || message.iframeURL?.isEmpty == false
        }
    }
}
