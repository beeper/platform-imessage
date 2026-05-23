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
private let pendingLinkPreviewTimeout: TimeInterval = 2 * 60
// How soon to re-tick when resolution work is outstanding and the database is
// otherwise idle. New-message chat joins normally settle within a second, so we
// poll them tightly; link previews can take much longer, so we poll them lazily.
private let pendingNewMessageWakeInterval: TimeInterval = 0.5
private let pendingLinkPreviewWakeInterval: TimeInterval = 5

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

        // Each tick recomputes which resolved rows are awaiting a send commit.
        newMessageRowIDsAwaitingSendCommit.removeAll(keepingCapacity: true)
        linkPreviewRowIDsAwaitingSendCommit.removeAll(keepingCapacity: true)

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

    /// Clear the rows resolved this tick from the pending maps once their events
    /// have been sent (or there was nothing to send). Re-evaluates the wake so it
    /// reflects the now-smaller pending set. Called by `watchForever` after a
    /// successful send; on a send failure it is skipped so the rows stay pending.
    func commitPendingSends() {
        for rowID in newMessageRowIDsAwaitingSendCommit {
            pendingUnresolvedNewMessageRowIDs.removeValue(forKey: rowID)
        }
        for rowID in linkPreviewRowIDsAwaitingSendCommit {
            pendingLinkPreviewCandidates.removeValue(forKey: rowID)
        }
        newMessageRowIDsAwaitingSendCommit.removeAll(keepingCapacity: true)
        linkPreviewRowIDsAwaitingSendCommit.removeAll(keepingCapacity: true)
        schedulePendingWakeIfNeeded()
    }

    /// Resolution of pending new messages and link previews only happens when
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
        } else if !pendingLinkPreviewCandidates.isEmpty {
            interval = pendingLinkPreviewWakeInterval
        } else {
            interval = nil
        }

        guard let interval else {
            pendingWakeTask = nil
            return
        }

        let changes = db.changes
        let nanoseconds = UInt64(interval * 1_000_000_000)
        pendingWakeTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            changes.broadcast(())
        }
    }

    private func messageUpdateEvents(for changes: [UpdatedMessageChange]) throws -> [ServerEvent] {
        guard !changes.isEmpty else {
            traceMessageUpdates("no messages updated this time around")
            return []
        }

        let changeRowIDs = OrderedSet(changes.map(\.rowID))
        let fetchedRows = try db.mappedMessageRows(rowIDs: Array(changeRowIDs))
        // `messageJoins` LEFT JOINs `chat_message_join`, so a message in multiple
        // chats yields multiple rows with the same ROWID. Keep first.
        var messageRowsByRowID = [Int: MappedMessageRow]()
        for row in fetchedRows where messageRowsByRowID[row.rowID] == nil {
            messageRowsByRowID[row.rowID] = row
        }

        // `resolvePendingLinkPreviewChanges` already fetched+mapped these rows to
        // decide whether a preview surfaced, but it's a cold path (the >=5s
        // preview wake), so we just re-fetch+remap here uniformly rather than
        // thread a precomputed cache through the call graph.
        let payloadRows = try PlatformAPI.messagePayloadRows(db: db, messageRows: Array(messageRowsByRowID.values), threadID: "")
        let mappedMessagesByRowID = try PlatformAPI.mapAndHashMessagesByRowID(
            messageRows: Array(messageRowsByRowID.values),
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
        trackPendingLinkPreviewCandidates(
            changes: changes,
            messageRowsByRowID: messageRowsByRowID,
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

        // A link preview lives in `payload_data`; until that column is populated
        // the expensive payload fetch + map/hash can't surface a preview. Map only
        // rows whose payload has actually landed so the rest stay pending cheaply
        // (just the `mappedMessageRows` join above) instead of paying the full
        // fetch-and-hash pass on every tick for up to the preview timeout.
        let readyRows = messageRowsByRowID.values.filter { $0.payloadData?.isEmpty == false }

        guard !readyRows.isEmpty else {
            // Only rows that are confirmed gone (no DB row) are safe to drop here,
            // since no fallible work remains. Rows still awaiting their payload
            // stay pending.
            for rowID in rowIDs where messageRowsByRowID[rowID] == nil {
                pendingLinkPreviewCandidates.removeValue(forKey: rowID)
            }
            return []
        }

        let payloadRows = try PlatformAPI.messagePayloadRows(db: db, messageRows: readyRows, threadID: "")
        let mappedMessagesByRowID = try PlatformAPI.mapAndHashMessagesByRowID(
            messageRows: readyRows,
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )

        // Defer every map mutation until after the throwing calls above. If
        // `messagePayloadRows`/`mapAndHashMessagesByRowID` throw, candidates stay
        // in the map and are retried on the next tick rather than silently lost.
        var changes: [UpdatedMessageChange] = []
        var goneRowIDs: [Int] = []
        for rowID in rowIDs {
            // Rows with no DB row are gone; drop them.
            guard let row = messageRowsByRowID[rowID] else {
                goneRowIDs.append(rowID)
                continue
            }

            guard let candidate = pendingLinkPreviewCandidates[rowID],
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
            // Keep the candidate pending until its preview event is sent
            // (commitPendingSends); a send failure then retries it next tick.
            linkPreviewRowIDsAwaitingSendCommit.append(rowID)
        }

        // Gone rows produce no event, so drop them now regardless of send.
        for rowID in goneRowIDs {
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

    // Outgoing link previews render asynchronously: Messages writes the message
    // row, then populates `payload_data` with the rich preview a moment later, so
    // we track the row and emit a follow-up `isPreviewUpdate` once the preview
    // lands. Known gaps (accepted, see plan-eng-review):
    //  - Incoming messages arrive with the sender's preview already embedded, so
    //    we only track outgoing rows (`isFromMe == 1`).
    //  - We only track rows that already carry the URL balloon kind at first
    //    sighting. If Messages inserts a plain-text row and flips
    //    `balloon_bundle_id` later (without bumping date_read/date_edited), or the
    //    watcher restarts between insert and hydration, the preview is missed,
    //    because the polling query only watches ROWID/date_read/date_edited.
    //  - The candidate is dropped on the first surfaced preview, so a richer
    //    preview that hydrates later (e.g. image/video attachment after link
    //    metadata) is not re-emitted, since attachment changes aren't tracked.
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
