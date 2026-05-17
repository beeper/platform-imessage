import IMDatabase
@testable import IMessage
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
        msgRowsByRowID: rows,
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
        msgRowsByRowID: [row.rowID: row],
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
        msgRowsByRowID: [row.rowID: row],
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

@Test func outgoingNewMessagesProduceSentMessageReportsAndKeepUpsertEvent() throws {
    let threadID = "any;-;fixture-contact-a@example.invalid"
    let messageGUID = "00000000-0000-4000-8000-000000000044"
    let row = try normalMessageRow(
        rowID: 7,
        guid: messageGUID,
        threadID: threadID,
        isFromMe: true
    )

    let result = try EventWatcher.messageUpdateResult(
        changes: [
            UpdatedMessageChange(rowID: row.rowID, chatGUID: threadID, isNew: true, wasRead: false, wasEdited: false),
        ],
        msgRowsByRowID: [row.rowID: row],
        attachmentRows: [],
        reactionRows: [],
        currentUserID: "fixture-self@example.invalid",
        accountID: "default"
    )

    let report = try #require(result.sentMessageReports.first)
    let eventObject = try #require(result.events.first?.jsonObject())

    #expect(result.sentMessageReports.count == 1)
    #expect(report.rowID == row.rowID)
    #expect(report.threadID == threadID)
    #expect(report.messages.first?.id == messageGUID)
    #expect(eventObject["objectName"] as? String == "message")
    #expect(eventObject["mutationType"] as? String == "upsert")
}

@Test func incomingNewMessagesDoNotProduceSentMessageReports() throws {
    let threadID = "any;-;fixture-contact-a@example.invalid"
    let row = try normalMessageRow(
        rowID: 8,
        guid: "00000000-0000-4000-8000-000000000045",
        threadID: threadID,
        isFromMe: false
    )

    let result = try EventWatcher.messageUpdateResult(
        changes: [
            UpdatedMessageChange(rowID: row.rowID, chatGUID: threadID, isNew: true, wasRead: false, wasEdited: false),
        ],
        msgRowsByRowID: [row.rowID: row],
        attachmentRows: [],
        reactionRows: [],
        currentUserID: "fixture-self@example.invalid",
        accountID: "default"
    )

    #expect(result.sentMessageReports.isEmpty)
    #expect(!result.events.isEmpty)
}

@Test func outgoingReactionActionRowsProduceSentMessageReports() throws {
    let threadID = "any;-;fixture-contact-a@example.invalid"
    let row = try reactionActionRow(
        rowID: 9,
        guid: "00000000-0000-4000-8000-000000000046",
        threadID: threadID,
        reactionType: 2001,
        replyToGUID: nil
    )

    let result = try EventWatcher.messageUpdateResult(
        changes: [
            UpdatedMessageChange(rowID: row.rowID, chatGUID: threadID, isNew: true, wasRead: false, wasEdited: false),
        ],
        msgRowsByRowID: [row.rowID: row],
        attachmentRows: [],
        reactionRows: [],
        currentUserID: "fixture-self@example.invalid",
        accountID: "default"
    )

    let report = try #require(result.sentMessageReports.first)
    #expect(result.sentMessageReports.count == 1)
    #expect(report.rowID == row.rowID)
    #expect(report.threadID == threadID)
    #expect(result.events.contains { $0.jsonObject()["objectName"] as? String == "message_reaction" })
}

@Test func sentMessageReportHubFiltersAndCleansObservers() async throws {
    let hub = SentMessageReportHub()
    let observation = hub.observe(after: 10)

    #expect(hub.observerCount == 1)

    hub.broadcast([
        SentMessageReport(rowID: 10, threadID: "thread-a", messages: []),
        SentMessageReport(rowID: 11, threadID: "thread-b", messages: []),
    ])

    var iterator = observation.stream.makeAsyncIterator()
    let report = await iterator.next()

    #expect(report?.rowID == 11)
    #expect(report?.threadID == "thread-b")

    observation.cancel()
    #expect(hub.observerCount == 0)
}

@Test func sentMessageReportHubCleansObserverWhenObservationIsCanceled() {
    let hub = SentMessageReportHub()
    let observation = hub.observe(after: 0)

    #expect(hub.observerCount == 1)
    observation.cancel()
    #expect(hub.observerCount == 0)
}

private func normalMessageRow(
    rowID: Int,
    guid: String,
    threadID: String,
    dateRead: Int? = nil,
    isFromMe: Bool = false
) throws -> MappedMessageRow {
    try MappedMessageRow(object: [
        "ROWID": rowID,
        "guid": guid,
        "date": rowID,
        "date_read": dateRead as Any,
        "is_from_me": isFromMe ? 1 : 0,
        "is_read": dateRead == nil ? 0 : 1,
        "handle_id": 1,
        "item_type": 0,
        "service": "iMessage",
        "text": "hello",
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
