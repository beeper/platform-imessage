import Foundation
import IMDatabase
@testable import IMessage
import IMessageCore
import PlatformSDK
import Testing

@Test func reactionStateSyncEventsPreserveChangeOrder() throws {
    let threadID = "any;-;fixture-contact-a@example.invalid"
    let firstActionGUID = "00000000-0000-4000-8000-000000000038"
    let secondActionGUID = "00000000-0000-4000-8000-000000000039"
    let thirdActionGUID = "00000000-0000-4000-8000-000000000040"
    let rows = try [
        2: reactionActionRow(rowID: 2, guid: firstActionGUID, threadID: threadID, reactionType: 2001, replyToGUID: nil),
        3: reactionActionRow(rowID: 3, guid: secondActionGUID, threadID: threadID, reactionType: 3001, replyToGUID: firstActionGUID),
        4: reactionActionRow(rowID: 4, guid: thirdActionGUID, threadID: threadID, reactionType: 2001, replyToGUID: secondActionGUID),
    ]

    let events = try EventWatcher.messageUpdateEvents(
        changes: [
            UpdatedMessageChange(rowID: 2, chatGUID: threadID, isNew: true, wasRead: false, wasEdited: false),
            UpdatedMessageChange(rowID: 3, chatGUID: threadID, isNew: true, wasRead: false, wasEdited: false),
            UpdatedMessageChange(rowID: 4, chatGUID: threadID, isNew: true, wasRead: false, wasEdited: false),
        ],
        messageRowsByRowID: rows,
        attachmentRows: [],
        reactionRows: [],
        currentUserID: "fixture-self@example.invalid",
        accountID: "default"
    )

    let reactionEvents = events
        .map { $0.jsonObject() }
        .filter { $0["objectName"] as? String == "message_reaction" }
    let reactionMutationTypes = reactionEvents.map { $0["mutationType"] as? String }
    let participantID = Hasher.participant.tokenizeRemembering(pii: "fixture-self@example.invalid")
    let reactionID = "\(participantID)like"
    let firstUpsertEntries = try #require(reactionEvents.first?["entries"] as? [JSONObject])
    let firstUpsert = try #require(firstUpsertEntries.first)
    let deleteEntries = try #require(reactionEvents.dropFirst().first?["entries"] as? [String])

    #expect(reactionMutationTypes == ["upsert", "delete", "upsert"])
    #expect(firstUpsert["id"] as? String == reactionID)
    #expect(firstUpsert["participantID"] as? String == participantID)
    #expect(deleteEntries == [reactionID])
}

@Test func existingReadChangesEmitMessageUpdate() throws {
    let threadID = "any;-;fixture-contact-a@example.invalid"
    let messageGUID = "00000000-0000-4000-8000-000000000041"
    let row = try normalMessageRow(rowID: 5, guid: messageGUID, threadID: threadID, dateRead: 1_000_000_000)

    let events = try EventWatcher.messageUpdateEvents(
        changes: [
            UpdatedMessageChange(rowID: row.rowID, chatGUID: threadID, isNew: false, wasRead: true, wasEdited: false),
        ],
        messageRowsByRowID: [row.rowID: row],
        attachmentRows: [],
        reactionRows: [],
        currentUserID: "fixture-self@example.invalid",
        accountID: "default"
    )

    let eventObject = try #require(events.first?.jsonObject())
    let entries = try #require(eventObject["entries"] as? [JSONObject])
    let patch = try #require(entries.first)

    #expect(events.count == 1)
    #expect(eventObject["objectName"] as? String == "message")
    #expect(eventObject["mutationType"] as? String == "update")
    #expect(patch["id"] as? String == messageGUID)
    #expect(patch["seen"] != nil)
    #expect(patch["behavior"] as? String == "keep_read")
}

@Test func newMessagesOnlyEmitUpsertEvenWhenRead() throws {
    let threadID = "any;-;fixture-contact-a@example.invalid"
    let row = try normalMessageRow(
        rowID: 6,
        guid: "00000000-0000-4000-8000-000000000042",
        threadID: threadID,
        dateRead: 1_000_000_000
    )

    let events = try EventWatcher.messageUpdateEvents(
        changes: [
            UpdatedMessageChange(rowID: row.rowID, chatGUID: threadID, isNew: true, wasRead: true, wasEdited: false),
        ],
        messageRowsByRowID: [row.rowID: row],
        attachmentRows: [],
        reactionRows: [],
        currentUserID: "fixture-self@example.invalid",
        accountID: "default"
    )

    let eventObject = try #require(events.first?.jsonObject())

    #expect(events.count == 1)
    #expect(eventObject["objectName"] as? String == "message")
    #expect(eventObject["mutationType"] as? String == "upsert")
}

@Test func missingChatJoinDefersNewMessageUntilLaterTick() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let rowID = 10
    let messageGUID = "00000000-0000-4000-8000-000000000044"
    try fixture.insertMessage(rowID: rowID, guid: messageGUID, text: "hello from deferred row")
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowID - 1)

    let firstTickEvents = try await watcher.collectMessageUpdateEvents()
    #expect(firstTickEvents.isEmpty)

    try fixture.insertChatJoin(messageRowID: rowID)

    let secondTickEvents = try await collectAndCommit(watcher)
    let eventObject = try firstMessageEventObject(in: secondTickEvents)
    let entry = try firstMessageEntry(in: eventObject)

    #expect(secondTickEvents.count == 1)
    #expect(eventObject["mutationType"] as? String == "upsert")
    #expect(entry["id"] as? String == messageGUID)
}

@Test func missingChatJoinDropsNewMessageAfterTimeout() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let rowID = 40
    try fixture.insertMessage(rowID: rowID, text: "never joins a chat")
    // Cursor already past the row so the main query returns nothing; only the
    // seeded pending entry drives this tick.
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowID)
    watcher.pendingUnresolvedNewMessageRowIDs[rowID] = Date().addingTimeInterval(-11)

    let events = try await watcher.collectMessageUpdateEvents()

    #expect(events.isEmpty)
    #expect(watcher.pendingUnresolvedNewMessageRowIDs[rowID] == nil)
    #expect(watcher.pendingWakeTask == nil)
}

@Test func pendingLinkPreviewExpiresAfterTimeout() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let rowID = 50
    try insertOutgoingURLMessage(
        fixture: fixture,
        rowID: rowID,
        guid: "00000000-0000-4000-8000-000000000050",
        text: "https://fixture.example.invalid/link"
    )
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowID)
    watcher.pendingMessageHydrationCandidates[rowID] = PendingMessageHydrationCandidate(
        firstSeen: Date().addingTimeInterval(-121),
        chatGUID: fixture.chatGUID,
        kind: .linkPreview
    )

    // Payload never landed; the candidate is past its budget and must be
    // dropped without emitting a spurious update.
    let events = try await watcher.collectMessageUpdateEvents()

    #expect(events.isEmpty)
    #expect(watcher.pendingMessageHydrationCandidates[rowID] == nil)
    #expect(watcher.pendingWakeTask == nil)
}

@Test func deferredNewMessageArmsWakeUntilResolved() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let rowID = 60
    try fixture.insertMessage(rowID: rowID, guid: "00000000-0000-4000-8000-000000000060", text: "deferred")
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowID - 1)

    let firstTickEvents = try await watcher.collectMessageUpdateEvents()
    #expect(firstTickEvents.isEmpty)
    // A wake is armed so the pending row still resolves if the DB goes quiet.
    #expect(watcher.pendingWakeTask != nil)

    try fixture.insertChatJoin(messageRowID: rowID)

    let secondTickEvents = try await collectAndCommit(watcher)
    #expect(secondTickEvents.count == 1)
    // Nothing left pending, so the wake is cleared.
    #expect(watcher.pendingWakeTask == nil)
}

@Test func outgoingURLPreviewPayloadUpdateEmitsMessageUpdateOnce() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let rowID = 20
    let messageGUID = "00000000-0000-4000-8000-000000000045"
    try insertOutgoingURLMessage(
        fixture: fixture,
        rowID: rowID,
        guid: messageGUID,
        text: "https://fixture.example.invalid/link"
    )
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowID - 1)

    let firstTickEvents = try await collectAndCommit(watcher)
    let firstEventObject = try firstMessageEventObject(in: firstTickEvents)
    let firstEntry = try firstMessageEntry(in: firstEventObject)

    #expect(firstEventObject["mutationType"] as? String == "upsert")
    #expect((firstEntry["links"] as? JSONArray)?.isEmpty != false)
    #expect((firstEntry["tweets"] as? JSONArray)?.isEmpty != false)
    #expect(firstEntry["iframeURL"] == nil)

    try fixture.updateMessagePayloadData(rowID: rowID, payloadData: try urlBalloonPayloadData())

    let secondTickEvents = try await collectAndCommit(watcher)
    let secondEventObject = try firstMessageEventObject(in: secondTickEvents)
    let patch = try firstMessageEntry(in: secondEventObject)
    let link = try firstLink(in: patch)

    #expect(secondTickEvents.count == 1)
    #expect(secondEventObject["mutationType"] as? String == "update")
    #expect(patch["id"] as? String == messageGUID)
    #expect(link["url"] as? String == "https://fixture.example.invalid/link")
    #expect(link["title"] as? String == "Fixture Link")

    let thirdTickEvents = try await collectAndCommit(watcher)
    #expect(thirdTickEvents.isEmpty)
}

@Test func loadingAttachmentEmitsFullUpdateWhenTransferFinishes() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let rowID = 21
    let attachmentRowID = 210
    let messageGUID = "00000000-0000-4000-8000-000000000047"
    try insertJoinedMessage(fixture: fixture, rowID: rowID, guid: messageGUID, text: "")
    try fixture.insertAttachment(
        rowID: attachmentRowID,
        messageRowID: rowID,
        guid: "00000000-0000-4000-8000-000000000210",
        filename: "/tmp/fixture-loading.jpg",
        totalBytes: 10,
        transferState: Attachment.IMFileTransferState.transferring.rawValue
    )
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowID - 1)

    let firstTickEvents = try await collectAndCommit(watcher)
    let firstEventObject = try firstMessageEventObject(in: firstTickEvents)
    let firstEntry = try firstMessageEntry(in: firstEventObject)
    let loadingAttachment = try firstAttachment(in: firstEntry)

    #expect(firstEventObject["mutationType"] as? String == "upsert")
    #expect(loadingAttachment["loading"] as? Bool == true)
    #expect(watcher.pendingMessageHydrationCandidates[rowID] != nil)
    #expect(watcher.pendingWakeTask != nil)

    try fixture.updateAttachmentTransferState(
        rowID: attachmentRowID,
        transferState: Attachment.IMFileTransferState.finished.rawValue
    )

    let secondTickEvents = try await collectAndCommit(watcher)
    let secondEventObject = try firstMessageEventObject(in: secondTickEvents)
    let patch = try firstMessageEntry(in: secondEventObject)
    let loadedAttachment = try firstAttachment(in: patch)

    #expect(secondTickEvents.count == 1)
    #expect(secondEventObject["mutationType"] as? String == "update")
    #expect(patch["id"] as? String == "\(messageGUID)_1")
    #expect(loadedAttachment["loading"] as? Bool == false)
    #expect(watcher.pendingMessageHydrationCandidates[rowID] == nil)
    #expect(watcher.pendingWakeTask == nil)
}

@Test func pendingAttachmentLoadExpiresAfterTimeout() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let rowID = 22
    try insertJoinedMessage(fixture: fixture, rowID: rowID, guid: "00000000-0000-4000-8000-000000000048", text: "")
    try fixture.insertAttachment(
        rowID: 220,
        messageRowID: rowID,
        filename: "/tmp/fixture-never-loads.jpg",
        transferState: Attachment.IMFileTransferState.transferring.rawValue
    )
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowID)
    watcher.pendingMessageHydrationCandidates[rowID] = PendingMessageHydrationCandidate(
        firstSeen: Date().addingTimeInterval(-121),
        chatGUID: fixture.chatGUID,
        kind: .attachmentLoad
    )

    let events = try await watcher.collectMessageUpdateEvents()

    #expect(events.isEmpty)
    #expect(watcher.pendingMessageHydrationCandidates[rowID] == nil)
    #expect(watcher.pendingWakeTask == nil)
}

@Test func readAndPreviewChangesForSameRowEmitOneFullUpdate() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let rowID = 30
    let messageGUID = "00000000-0000-4000-8000-000000000046"
    try insertOutgoingURLMessage(
        fixture: fixture,
        rowID: rowID,
        guid: messageGUID,
        text: "https://fixture.example.invalid/link"
    )
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowID - 1)

    let firstTickEvents = try await collectAndCommit(watcher)
    #expect(firstTickEvents.count == 1)

    try fixture.updateMessagePayloadData(rowID: rowID, payloadData: try urlBalloonPayloadData())
    try fixture.database.execute(
        sqlWithoutEscaping: "UPDATE message SET date_read = ?, is_read = 1 WHERE ROWID = ?",
        1_000_000_000,
        rowID
    )

    let secondTickEvents = try await collectAndCommit(watcher)
    let eventObject = try firstMessageEventObject(in: secondTickEvents)
    let patch = try firstMessageEntry(in: eventObject)
    let link = try firstLink(in: patch)

    #expect(secondTickEvents.count == 1)
    #expect(eventObject["mutationType"] as? String == "update")
    #expect(patch["id"] as? String == messageGUID)
    #expect(patch["senderID"] != nil)
    #expect(link["title"] as? String == "Fixture Link")
}

@Test func batchResolvesPendingNewMessagesIndependently() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    // rowA has a chat join and resolves this tick.
    let rowA = 80
    try insertJoinedMessage(fixture: fixture, rowID: rowA, guid: "00000000-0000-4000-8000-000000000080", text: "resolves")
    // rowB has no chat join yet and stays pending.
    let rowB = 81
    try fixture.insertMessage(rowID: rowB, text: "still pending")
    // rowC has no chat join and is past the join budget, so it's dropped.
    let rowC = 82
    try fixture.insertMessage(rowID: rowC, text: "times out")

    // Cursor past every row so the main query returns nothing; only the seeded
    // pending entries drive this tick.
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowC)
    let now = Date()
    watcher.pendingUnresolvedNewMessageRowIDs[rowA] = now
    watcher.pendingUnresolvedNewMessageRowIDs[rowB] = now
    watcher.pendingUnresolvedNewMessageRowIDs[rowC] = now.addingTimeInterval(-11)

    let events = try await collectAndCommit(watcher)
    let eventObject = try firstMessageEventObject(in: events)

    // Only rowA produced an event; rowB stays pending; rowC was dropped.
    #expect(events.count == 1)
    #expect(eventObject["mutationType"] as? String == "upsert")
    #expect(watcher.pendingUnresolvedNewMessageRowIDs[rowA] == nil)
    #expect(watcher.pendingUnresolvedNewMessageRowIDs[rowB] != nil)
    #expect(watcher.pendingUnresolvedNewMessageRowIDs[rowC] == nil)
}

@Test func collectionErrorKeepsPendingWakeArmed() async throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    let rowID = 70
    let watcher = try fixtureEventWatcher(fixture: fixture, lastRowID: rowID)
    // A new message is awaiting chat-join resolution, well within budget.
    watcher.pendingUnresolvedNewMessageRowIDs[rowID] = Date()

    // Break the database so this tick throws while pending work remains.
    try fixture.database.execute(sqlWithoutEscaping: "DROP TABLE message")

    await #expect(throws: (any Error).self) {
        try await watcher.collectMessageUpdateEvents()
    }

    // The `defer` re-armed the wake despite the throw, so the still-pending row
    // keeps getting re-poked instead of being stranded on a quiet DB.
    #expect(watcher.pendingWakeTask != nil)
    #expect(watcher.pendingUnresolvedNewMessageRowIDs[rowID] != nil)
}

private func insertJoinedMessage(
    fixture: TahoeChatDatabaseFixture,
    rowID: Int,
    guid: String,
    text: String
) throws {
    try fixture.insertMessage(rowID: rowID, guid: guid, text: text)
    try fixture.insertChatJoin(messageRowID: rowID)
}

private func normalMessageRow(
    rowID: Int,
    guid: String,
    threadID: String,
    dateRead: Int? = nil,
    text: String = "hello"
) throws -> MappedMessageRow {
    try MappedMessageRow(object: [
        "ROWID": rowID,
        "guid": guid,
        "date": rowID,
        "date_read": dateRead as Any,
        "is_from_me": 0,
        "is_read": dateRead == nil ? 0 : 1,
        "handle_id": 1,
        "item_type": 0,
        "service": "iMessage",
        "text": text,
        "threadID": threadID,
        "participantID": "fixture-contact-a@example.invalid",
    ])
}

private func reactionActionRow(
    rowID: Int,
    guid: String,
    threadID: String,
    reactionType: Int,
    replyToGUID: String?
) throws -> MappedMessageRow {
    try MappedMessageRow(object: [
        "ROWID": rowID,
        "guid": guid,
        "date": rowID,
        "is_from_me": 1,
        "handle_id": 0,
        "item_type": 0,
        "service": "iMessage",
        "threadID": threadID,
        "associated_message_guid": "00000000-0000-4000-8000-000000000043",
        "associated_message_type": reactionType,
        "reply_to_guid": replyToGUID as Any,
    ])
}

/// Mirrors `watchForever`'s success path: collect a tick's events, then commit
/// the pending-send removals as if the (no-op) sender had succeeded. Tests that
/// assert post-resolution pending/wake state must commit, since resolved rows
/// now stay pending until their events are sent.
private func collectAndCommit(_ watcher: EventWatcher) async throws -> [ServerEvent] {
    let events = try await watcher.collectMessageUpdateEvents()
    watcher.commitPendingSends()
    return events
}

private func fixtureEventWatcher(
    fixture: TahoeChatDatabaseFixture,
    lastRowID: Int
) throws -> EventWatcher {
    try EventWatcher(
        serverEventSender: { _ in },
        initialUpdatesCursor: MessageUpdatesCursor(
            lastRowID: lastRowID,
            lastDateReadNanoseconds: 0,
            lastDateEditedNanoseconds: 0
        ),
        currentUserID: "fixture-self@example.invalid",
        accountID: "default",
        db: fixture.imDatabase
    )
}

private func insertOutgoingURLMessage(
    fixture: TahoeChatDatabaseFixture,
    rowID: Int,
    guid: String,
    text: String
) throws {
    try fixture.insertMessage(rowID: rowID, guid: guid)
    try fixture.database.execute(
        sqlWithoutEscaping: """
        UPDATE message
        SET text = ?, is_from_me = 1, is_sent = 1, is_delivered = 1, balloon_bundle_id = ?
        WHERE ROWID = ?
        """,
        text,
        BalloonBundleKind.url.rawValue,
        rowID
    )
    try fixture.insertChatJoin(messageRowID: rowID)
}

private func urlBalloonPayloadData() throws -> Data {
    let values = try loadFixture("message_url_balloon")
    let messageRow = try #require(values.first as? FixtureJSONObject)
    return try #require(messageRow["payload_data"] as? Data)
}

private func firstMessageEventObject(in events: [ServerEvent]) throws -> JSONObject {
    let eventObject = try #require(events.first?.jsonObject())
    #expect(eventObject["objectName"] as? String == "message")
    return eventObject
}

private func firstMessageEntry(in eventObject: JSONObject) throws -> JSONObject {
    let entries = try #require(eventObject["entries"] as? [JSONObject])
    return try #require(entries.first)
}

private func firstLink(in messageObject: JSONObject) throws -> JSONObject {
    let links = try #require(messageObject["links"] as? [JSONObject])
    return try #require(links.first)
}

private func firstAttachment(in messageObject: JSONObject) throws -> JSONObject {
    let attachments = try #require(messageObject["attachments"] as? [JSONObject])
    return try #require(attachments.first)
}
