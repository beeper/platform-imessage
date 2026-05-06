import IMDatabase
@testable import IMessage
import PlatformSDK
import Testing

@Test func reactionStateSyncEventsPreserveChangeOrder() throws {
    let threadID = "any;-;+15551234567"
    let rows = try [
        2: reactionActionRow(rowID: 2, guid: "ACTION-1", threadID: threadID, reactionType: 2001, replyToGUID: nil),
        3: reactionActionRow(rowID: 3, guid: "ACTION-2", threadID: threadID, reactionType: 3001, replyToGUID: "ACTION-1"),
        4: reactionActionRow(rowID: 4, guid: "ACTION-3", threadID: threadID, reactionType: 2001, replyToGUID: "ACTION-2"),
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
        currentUserID: "me@example.com",
        accountID: "default"
    )

    let reactionEvents = events
        .map { $0.jsonObject() }
        .filter { $0["objectName"] as? String == "message_reaction" }
    let reactionMutationTypes = reactionEvents.map { $0["mutationType"] as? String }
    let participantID = Hasher.participant.tokenizeRemembering(pii: "me@example.com")
    let reactionID = "\(participantID)like"
    let firstUpsertEntries = try #require(reactionEvents.first?["entries"] as? [JSONObject])
    let firstUpsert = try #require(firstUpsertEntries.first)
    let deleteEntries = try #require(reactionEvents.dropFirst().first?["entries"] as? [String])

    #expect(reactionMutationTypes == ["upsert", "delete", "upsert"])
    #expect(firstUpsert["id"] as? String == reactionID)
    #expect(firstUpsert["participantID"] as? String == participantID)
    #expect(deleteEntries == [reactionID])
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
        "associated_message_guid": "TARGET-MESSAGE",
        "associated_message_type": reactionType,
        "reply_to_guid": replyToGUID as Any,
    ])
}
