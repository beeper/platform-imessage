import Collections
import Foundation
import IMDatabase
import IMessageCore
import Logging
import PlatformSDK

private let log = Logger(imessageLabel: "event-watcher.updates")
// Deferred chat-join resolution is non-blocking (it costs only a cheap batched
// join per quiet-DB wake), so we can afford a generous budget before giving up
// on a new message whose chat_message_join row never becomes visible.
private let pendingChatJoinTimeout: TimeInterval = 10
private let pendingMessageHydrationTimeout: TimeInterval = 2 * 60
// How soon to re-tick when resolution work is outstanding and the database is
// otherwise idle. New-message chat joins normally settle within a second, so we
// poll them tightly; previews and attachments can take longer, so we reuse the
// existing lazy hydration wake for both.
private let pendingNewMessageWakeInterval: TimeInterval = 0.5
private let pendingMessageHydrationWakeInterval: TimeInterval = 5

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
        let mappedMessagesByRowID = try PlatformAPI.mapAndHashMessagesByRowID(
            messageRows: Array(messageRowsByRowID.values),
            attachmentRows: attachmentRows,
            reactionRows: reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
        return try messageUpdateEventContext(
            changes: changes,
            messageRowsByRowID: messageRowsByRowID,
            mappedMessagesByRowID: mappedMessagesByRowID,
            currentUserID: currentUserID,
            accountID: accountID
        ).events
    }

    private static func messageUpdateEventContext(
        changes: [UpdatedMessageChange],
        messageRowsByRowID: [Int: MappedMessageRow],
        mappedMessagesByRowID: [Int: [PlatformSDK.Message]],
        currentUserID: String,
        accountID: String
    ) throws -> MessageUpdateEventContext {
        guard !changes.isEmpty else {
            traceMessageUpdates("no messages updated this time around")
            return MessageUpdateEventContext(events: [], mappedMessagesByRowID: [:])
        }

        let mergedChanges = mergedChangesByRowID(changes)
        var pendingByRowID = OrderedDictionary<Int, PendingMessage>()

        for change in mergedChanges {
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
            mappedMessagesByRowID: mappedMessagesByRowID
        )
    }

    func collectMessageUpdateEvents() async throws -> [ServerEvent] {
        // Re-arm the wake on every exit, including a thrown tick. Pending work
        // must keep being re-poked when the DB goes quiet, regardless of a
        // mid-tick failure — otherwise a single throw strands pending rows until
        // an unrelated filesystem change happens to tick again.
        defer { schedulePendingWakeIfNeeded() }

        newMessageRowIDsAwaitingSendCommit.removeAll(keepingCapacity: true)
        messageHydrationRowIDsAwaitingSendCommit.removeAll(keepingCapacity: true)

        let queryResult = try db.messages(since: updatesCursor)
        traceMessageUpdates(
            "updated messages query returned \(queryResult.updatedMessages.count) updated message(s) and \(queryResult.unresolvedNewMessageRowIDs.count) unresolved new message(s)"
        )

        var changes = try resolvePendingNewMessageChanges()
        let hydrationChanges = try resolvePendingMessageHydrationChanges()
        rememberPendingNewMessages(rowIDs: queryResult.unresolvedNewMessageRowIDs)

        changes.append(contentsOf: queryResult.updatedMessages)
        changes.append(contentsOf: hydrationChanges)

        let events = try messageUpdateEvents(for: changes)
        traceMessageUpdates("done computing message state syncs, updating the messages updates cursor to: \(queryResult.nextCursor)")
        updatesCursor = queryResult.nextCursor
        return events
    }

    /// Clear the rows resolved this tick from the pending maps once their events
    /// have been sent (or there was nothing to send). Re-evaluates the wake so it
    /// reflects the now-smaller pending set. Called by `watchForever` after a
    /// successful send; on a send failure it is skipped so the rows stay pending.
    func commitPendingSends() {
        for rowID in newMessageRowIDsAwaitingSendCommit {
            pendingUnresolvedNewMessageRowIDs.removeValue(forKey: rowID)
        }
        for rowID in messageHydrationRowIDsAwaitingSendCommit {
            pendingMessageHydrationCandidates.removeValue(forKey: rowID)
        }
        newMessageRowIDsAwaitingSendCommit.removeAll(keepingCapacity: true)
        messageHydrationRowIDsAwaitingSendCommit.removeAll(keepingCapacity: true)
        schedulePendingWakeIfNeeded()
    }

    /// Resolution of pending new messages and hydration only happens when
    /// `collectMessageUpdateEvents` runs, which is otherwise driven solely by
    /// filesystem-change ticks. If the database goes quiet, arm a one-shot wake
    /// so outstanding work still resolves (or expires) within its budget. The
    /// task only pokes the change topic; all watcher state stays owned by the
    /// single `watchForever` consumer loop, so there's no cross-task mutation.
    private func schedulePendingWakeIfNeeded() {
        pendingWakeTask?.cancel()

        let interval: TimeInterval?
        if !pendingUnresolvedNewMessageRowIDs.isEmpty {
            interval = pendingNewMessageWakeInterval
        } else if !pendingMessageHydrationCandidates.isEmpty {
            interval = pendingMessageHydrationWakeInterval
        } else {
            interval = nil
        }

        guard let interval else {
            pendingWakeTask = nil
            return
        }

        let changes = db.changes
        pendingWakeTask = Task {
            try? await Task.sleep(forTimeInterval: interval)
            guard !Task.isCancelled else { return }
            changes.broadcast(())
        }
    }

    private func messageUpdateEvents(for changes: [UpdatedMessageChange]) throws -> [ServerEvent] {
        guard !changes.isEmpty else {
            traceMessageUpdates("no messages updated this time around")
            return []
        }

        // `mappedMessageRows` deduplicates the row IDs internally before querying.
        let fetchedRows = try db.mappedMessageRows(rowIDs: changes.map(\.rowID))
        // `messageJoins` LEFT JOINs `chat_message_join`, so a message in multiple
        // chats yields multiple rows with the same ROWID. Keep first.
        let messageRowsByRowID = Dictionary(fetchedRows.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
        let messageRows = Array(messageRowsByRowID.values)

        // `resolvePendingMessageHydrationChanges` already fetched+mapped these
        // rows to decide whether a preview or attachment surfaced, but it's a
        // cold path (the >=5s hydration wake), so we just re-fetch+remap here
        // rather than thread a precomputed cache through the call graph.
        let payloadRows = try PlatformAPI.messagePayloadRows(db: db, messageRows: messageRows, threadID: "")
        let mappedMessagesByRowID = try PlatformAPI.mapAndHashMessagesByRowID(
            messageRows: messageRows,
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )

        let context = try Self.messageUpdateEventContext(
            changes: changes,
            messageRowsByRowID: messageRowsByRowID,
            mappedMessagesByRowID: mappedMessagesByRowID,
            currentUserID: currentUserID,
            accountID: accountID
        )
        trackPendingMessageHydrationCandidates(
            changes: changes,
            messageRowsByRowID: messageRowsByRowID,
            mappedMessagesByRowID: context.mappedMessagesByRowID
        )
        return context.events
    }

    private enum MessageUpdateKind {
        case full, read

        init?(_ change: UpdatedMessageChange) {
            // Full patches dominate read receipts: a same-tick edit/hydration+read
            // replaces stale merged message state in one update event.
            if change.wasEdited || change.isHydrationUpdate {
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
        var timedOutRowIDs: [Int] = []

        // Resolve all pending row IDs in a single batched join instead of one
        // `threadIDForMessage` query per row. `mappedMessageRows` performs the
        // same LEFT JOIN; rows still missing a chat join have a nil threadID and
        // stay pending until they resolve or time out.
        let messageRows = try db.mappedMessageRows(rowIDs: Array(pendingUnresolvedNewMessageRowIDs.keys))
        let threadIDByRowID = Dictionary(
            messageRows.compactMap { row in row.threadID.map { (row.rowID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        for (rowID, firstSeen) in pendingUnresolvedNewMessageRowIDs {
            if let chatGUID = threadIDByRowID[rowID] {
                resolvedChanges.append(UpdatedMessageChange(
                    rowID: rowID,
                    chatGUID: chatGUID,
                    isNew: true,
                    wasRead: false,
                    wasEdited: false
                ))
                // Keep the row pending until its event is sent (commitPendingSends).
                // The main-query cursor already advanced past it, so pending is the
                // only recovery path if the send fails.
                newMessageRowIDsAwaitingSendCommit.append(rowID)
                continue
            }

            if now.timeIntervalSince(firstSeen) >= pendingChatJoinTimeout {
                log.error("couldn't join message \(rowID) to chat after deferred ticks, dropping")
                timedOutRowIDs.append(rowID)
            }
        }

        // Timed-out rows produce no event, so drop them now regardless of send.
        for rowID in timedOutRowIDs {
            pendingUnresolvedNewMessageRowIDs.removeValue(forKey: rowID)
        }

        return resolvedChanges
    }

    private func resolvePendingMessageHydrationChanges() throws -> [UpdatedMessageChange] {
        guard !pendingMessageHydrationCandidates.isEmpty else {
            return []
        }

        expirePendingMessageHydrationCandidates()
        guard !pendingMessageHydrationCandidates.isEmpty else {
            return []
        }

        let rowIDs = Array(pendingMessageHydrationCandidates.keys)
        let messageRows = try db.mappedMessageRows(rowIDs: rowIDs)
        let messageRowsByRowID = Dictionary(messageRows.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })

        // Candidates whose row has vanished produce no event and have no fallible
        // work left, so drop them now regardless of what the payload pass finds.
        for rowID in rowIDs where messageRowsByRowID[rowID] == nil {
            pendingMessageHydrationCandidates.removeValue(forKey: rowID)
        }

        // Cheap gate before the expensive payload fetch + map/hash. A link preview
        // lives in `payload_data`, so rows whose payload hasn't landed stay pending
        // for just the join cost. Attachment readiness lives in the `attachment`
        // table, so read those rows' transfer_state directly: rows with every
        // attachment finished graduate to the payload pass; terminally-failed (or
        // attachment-less) rows are dropped now since they'll never resolve;
        // still-transferring rows stay pending.
        let attachmentRowIDs = messageRows.compactMap { row in
            pendingMessageHydrationCandidates[row.rowID]?.kind == .attachmentLoad ? row.rowID : nil
        }
        let transferStates = try attachmentTransferStates(forMessageRowIDs: attachmentRowIDs)

        var hydratableRows: [MappedMessageRow] = []
        for row in messageRows {
            switch pendingMessageHydrationCandidates[row.rowID]?.kind {
            case .linkPreview:
                if row.payloadData?.isEmpty == false {
                    hydratableRows.append(row)
                }
            case .attachmentLoad:
                let states = transferStates[row.rowID] ?? []
                if states.isEmpty || states.contains(where: \.isTerminalFailure) {
                    pendingMessageHydrationCandidates.removeValue(forKey: row.rowID)
                } else if states.allSatisfy({ $0 == .finished }) {
                    hydratableRows.append(row)
                }
            case nil:
                break
            }
        }
        guard !hydratableRows.isEmpty else {
            return []
        }

        let payloadRows = try PlatformAPI.messagePayloadRows(db: db, messageRows: hydratableRows, threadID: "")
        let mappedMessagesByRowID = try PlatformAPI.mapAndHashMessagesByRowID(
            messageRows: hydratableRows,
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )

        var changes: [UpdatedMessageChange] = []
        for row in hydratableRows {
            guard let candidate = pendingMessageHydrationCandidates[row.rowID] else {
                continue
            }

            // Attachments were already confirmed finished by the transfer_state
            // gate; a link preview needs a second look because a populated
            // `payload_data` doesn't guarantee a preview actually surfaced.
            if candidate.kind == .linkPreview,
               !Self.mappedMessagesContainPreview(mappedMessagesByRowID[row.rowID] ?? []) {
                continue
            }

            changes.append(UpdatedMessageChange(
                rowID: row.rowID,
                chatGUID: row.threadID ?? candidate.chatGUID,
                isNew: false,
                wasRead: false,
                wasEdited: false,
                isHydrationUpdate: true
            ))
            // Keep the candidate pending until its hydration event is sent
            // (commitPendingSends); a send failure then retries it next tick.
            messageHydrationRowIDsAwaitingSendCommit.append(row.rowID)
        }

        return changes
    }

    private func attachmentTransferStates(forMessageRowIDs messageRowIDs: [Int]) throws -> [Int: [Attachment.IMFileTransferState]] {
        guard !messageRowIDs.isEmpty else { return [:] }
        var byMessageRowID: [Int: [Attachment.IMFileTransferState]] = [:]
        for attachmentRow in try db.mappedAttachmentRows(messageRowIDs: messageRowIDs) {
            guard let rawTransferState = attachmentRow.transferState else { continue }
            byMessageRowID[attachmentRow.msgRowID, default: []]
                .append(Attachment.IMFileTransferState(rawValue: rawTransferState))
        }
        return byMessageRowID
    }

    private func expirePendingMessageHydrationCandidates() {
        let now = Date()
        let expiredRowIDs = pendingMessageHydrationCandidates.compactMap { element -> Int? in
            let (rowID, candidate) = element
            return now.timeIntervalSince(candidate.firstSeen) >= pendingMessageHydrationTimeout ? rowID : nil
        }
        for rowID in expiredRowIDs {
            pendingMessageHydrationCandidates.removeValue(forKey: rowID)
        }
    }

    // Some message content hydrates after the row is first written, so we track
    // the row and emit a follow-up `isHydrationUpdate` once it lands. Two kinds:
    //
    //  - Link preview: Messages writes the row, then populates `payload_data`
    //    with the rich preview a moment later. Tracked for OUTGOING URL rows only
    //    (`isFromMe == 1`, URL balloon) — incoming messages arrive with the
    //    sender's preview already embedded. Resolved when a preview surfaces.
    //  - Attachment load: an attachment row starts at a transferring state and
    //    flips to `finished` once the file lands. Tracked for ANY direction
    //    (incoming downloads and outgoing uploads alike) whenever a mapped
    //    attachment is still `loading`. Resolved when every attachment finishes;
    //    a terminal `transfer_state` failure drops the candidate without an event.
    //
    // Known gaps (accepted, see plan-eng-review):
    //  - Both kinds rely on the row appearing in `changes` while still un-hydrated.
    //    The polling query only watches ROWID/date_read/date_edited, so if Messages
    //    flips `balloon_bundle_id`/`transfer_state` without bumping those columns,
    //    or the watcher restarts between insert and hydration, the follow-up is
    //    missed.
    //  - A link-preview candidate is dropped on the first surfaced preview, so a
    //    richer preview that adds attachments after the link metadata is missed
    //    unless an earlier emitted state already carried those attachments as
    //    `loading`.
    //  - A terminally-failed attachment is dropped silently: we stop polling but
    //    don't emit a corrective event, so the last-sent `loading` state sticks in
    //    the consumer (tracked separately — surface a failed attachment state).
    private func trackPendingMessageHydrationCandidates(
        changes: [UpdatedMessageChange],
        messageRowsByRowID: [Int: MappedMessageRow],
        mappedMessagesByRowID: [Int: [PlatformSDK.Message]]
    ) {
        let now = Date()
        let rowsAwaitingSend = Set(messageHydrationRowIDsAwaitingSendCommit)
        for change in changes where !rowsAwaitingSend.contains(change.rowID) {
            guard let row = messageRowsByRowID[change.rowID] else {
                continue
            }

            let mappedMessages = mappedMessagesByRowID[row.rowID] ?? []
            if change.isNew,
               row.isFromMe == 1,
               row.balloonBundleID == BalloonBundleKind.url.rawValue,
               !Self.mappedMessagesContainPreview(mappedMessages) {
                rememberPendingMessageHydrationCandidate(
                    row: row,
                    change: change,
                    firstSeen: now,
                    kind: .linkPreview
                )
            } else if Self.mappedMessagesContainLoadingAttachments(mappedMessages) {
                rememberPendingMessageHydrationCandidate(
                    row: row,
                    change: change,
                    firstSeen: now,
                    kind: .attachmentLoad
                )
            } else if pendingMessageHydrationCandidates[row.rowID]?.kind == .attachmentLoad {
                pendingMessageHydrationCandidates.removeValue(forKey: row.rowID)
            }
        }
    }

    private func rememberPendingMessageHydrationCandidate(
        row: MappedMessageRow,
        change: UpdatedMessageChange,
        firstSeen: Date,
        kind: PendingMessageHydrationKind
    ) {
        guard pendingMessageHydrationCandidates[row.rowID] == nil else {
            return
        }
        pendingMessageHydrationCandidates[row.rowID] = PendingMessageHydrationCandidate(
            firstSeen: firstSeen,
            chatGUID: row.threadID ?? change.chatGUID,
            kind: kind
        )
    }

    private static func mappedMessagesContainPreview(_ messages: [PlatformSDK.Message]) -> Bool {
        messages.contains { message in
            message.links?.isEmpty == false
                || message.tweets?.isEmpty == false
                || message.iframeURL?.isEmpty == false
        }
    }

    private static func mappedMessagesContainLoadingAttachments(_ messages: [PlatformSDK.Message]) -> Bool {
        messages.contains { message in
            message.attachments?.contains { $0.loading == true } == true
        }
    }
}
