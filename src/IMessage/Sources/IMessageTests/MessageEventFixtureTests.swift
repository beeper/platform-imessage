import IMDatabase
@testable import IMessage
import PlatformSDK
import Testing

private struct MessageEventFixture: @unchecked Sendable {
    let fileName: String
    let change: MessageEventChange
    let expected: [ServerEvent]
}

private struct MessageEventChange: Sendable {
    let isNew: Bool
    let wasRead: Bool
    let wasEdited: Bool

    static let new = MessageEventChange(isNew: true, wasRead: false, wasEdited: false)
    static let edited = MessageEventChange(isNew: false, wasRead: false, wasEdited: true)
    static let read = MessageEventChange(isNew: false, wasRead: true, wasEdited: false)
}

private let fixtureSelf = "fixture-self@example.invalid"
private let fixtureContactA = "fixture-contact-a@example.invalid"
private let directThreadID = hashedThread("iMessage;-;\(fixtureContactA)")
private let groupThreadID = hashedThread("iMessage;+;fixture-group-001")
private let selfParticipantID = hashedParticipant(fixtureSelf)
private let contactParticipantID = hashedParticipant(fixtureContactA)

private let messageEventFixtures = [
    MessageEventFixture(
        fileName: "message_event_edited",
        change: .edited,
        expected: [
            .updateMessages(threadID: directThreadID, patches: [[
                "id": "00000000-0000-4000-8000-000000000006",
                "text": "edited fixture",
            ]]),
        ]
    ),
    MessageEventFixture(
        fileName: "message_event_read",
        change: .read,
        expected: [
            .updateMessages(threadID: directThreadID, patches: [[
                "id": "00000000-0000-4000-8000-000000000007",
                "seen": 1_700_000_420_000,
                "behavior": "keep_read",
            ]]),
        ]
    ),
    MessageEventFixture(
        fileName: "message_event_new_incoming",
        change: .new,
        expected: [
            .upsertMessages(threadID: groupThreadID, messages: [
                message(
                    id: "00000000-0000-4000-8000-000000000008",
                    timestamp: 1_700_000_480_000,
                    senderID: contactParticipantID,
                    text: "incoming fixture"
                ),
            ]),
        ]
    ),
    MessageEventFixture(
        fileName: "message_event_new_outgoing",
        change: .new,
        expected: [
            .upsertMessages(threadID: directThreadID, messages: [
                message(
                    id: "00000000-0000-4000-8000-000000000009",
                    timestamp: 1_700_000_540_000,
                    senderID: selfParticipantID,
                    text: "outgoing fixture"
                ),
            ]),
        ]
    ),
    MessageEventFixture(
        fileName: "message_event_reaction_add",
        change: .new,
        expected: [
            .upsertMessageReactions(
                threadID: directThreadID,
                messageID: "00000000-0000-4000-8000-000000000011",
                reactions: [
                    PlatformSDK.MessageReaction(
                        id: messageReactionID(participantID: selfParticipantID, reactionKey: "like"),
                        reactionKey: "like",
                        participantID: selfParticipantID
                    ),
                ]
            ),
            .upsertMessages(
                threadID: directThreadID,
                messages: [
                    message(
                        id: "00000000-0000-4000-8000-000000000010",
                        timestamp: 1_700_000_600_000,
                        senderID: selfParticipantID,
                        text: "You liked a message",
                        isHidden: true,
                        isAction: true,
                        parseTemplate: true,
                        linkedMessageID: "00000000-0000-4000-8000-000000000011",
                        action: .messageReactionCreated(PlatformSDK.PartialMessageReactionAction(
                            messageID: "00000000-0000-4000-8000-000000000011",
                            reactionKey: "like",
                            participantID: fixtureSelf
                        ))
                    ),
                ]
            ),
        ]
    ),
    MessageEventFixture(
        fileName: "message_event_reaction_remove",
        change: .new,
        expected: [
            .deleteMessageReactions(
                threadID: directThreadID,
                messageID: "00000000-0000-4000-8000-000000000011",
                ids: [messageReactionID(participantID: contactParticipantID, reactionKey: "heart")]
            ),
            .upsertMessages(
                threadID: directThreadID,
                messages: [
                    message(
                        id: "00000000-0000-4000-8000-000000000012",
                        timestamp: 1_700_000_660_000,
                        senderID: contactParticipantID,
                        text: "{{sender}} removed a heart from a message",
                        isHidden: true,
                        isAction: true,
                        parseTemplate: true,
                        linkedMessageID: "00000000-0000-4000-8000-000000000011",
                        action: .messageReactionDeleted(PlatformSDK.PartialMessageReactionAction(
                            messageID: "00000000-0000-4000-8000-000000000011",
                            reactionKey: "heart",
                            participantID: fixtureContactA
                        ))
                    ),
                ]
            ),
        ]
    ),
    MessageEventFixture(
        fileName: "message_event_undo_send",
        change: .edited,
        expected: [
            .updateMessages(threadID: directThreadID, patches: [[
                "id": "00000000-0000-4000-8000-000000000013",
                "text": "{{sender}} unsent a message",
                "attachments": JSONArray(),
                "reactions": JSONArray(),
                "tweets": JSONArray(),
                "links": JSONArray(),
                "isAction": true,
                "parseTemplate": true,
            ]]),
        ]
    ),
]

@Test(arguments: messageEventFixtures)
private func messageEventFixtureConvertsToServerEvents(fixture: MessageEventFixture) throws {
    let events = try loadServerEvents(fixture)

    #expect(events.containPartialServerEvents(fixture.expected))
}

@Test
private func reactionActionsDoNotEmitMessageDeletes() throws {
    for fileName in ["message_event_reaction_add", "message_event_reaction_remove"] {
        let events = try loadServerEvents(fileName: fileName, change: .new)

        #expect(events.containPartialServerEvents(expectedEvents(fileName: fileName)))
        #expect(!events.containsMessageDeleteEvent)
    }
}

@Test
private func undoSendEventClearsRichMessageFields() throws {
    let events = try loadServerEvents(fileName: "message_event_undo_send", change: .edited)
    let eventObject = try #require(events.first?.jsonObject())
    let entries = try #require(eventObject["entries"] as? [JSONObject])
    let patch = try #require(entries.first)

    #expect((patch["attachments"] as? JSONArray)?.isEmpty == true)
    #expect((patch["reactions"] as? JSONArray)?.isEmpty == true)
    #expect((patch["tweets"] as? JSONArray)?.isEmpty == true)
    #expect((patch["links"] as? JSONArray)?.isEmpty == true)
}

private func loadServerEvents(_ fixture: MessageEventFixture) throws -> [ServerEvent] {
    try loadServerEvents(fileName: fixture.fileName, change: fixture.change)
}

private func loadServerEvents(
    fileName: String,
    change: MessageEventChange
) throws -> [ServerEvent] {
    let values = try loadFixture(fileName)
    #expect(values.count == 5)

    let msgRowObject = try #require(values[0] as? FixtureJSONObject)
    let attachmentRowObjects = try #require(values[1] as? [FixtureJSONObject])
    let reactionRowObjects = try #require(values[2] as? [FixtureJSONObject])
    let currentUserID = try #require(values[3] as? String)
    let accountID = try #require(values[4] as? String)

    let msgRow = try MappedMessageRow(object: msgRowObject)
    return try EventWatcher.messageUpdateEvents(
        changes: [
            UpdatedMessageChange(
                rowID: msgRow.rowID,
                chatGUID: msgRow.threadID ?? "",
                isNew: change.isNew,
                wasRead: change.wasRead,
                wasEdited: change.wasEdited
            ),
        ],
        msgRowsByRowID: [msgRow.rowID: msgRow],
        attachmentRows: try attachmentRowObjects.map(MappedAttachmentRow.init(object:)),
        reactionRows: try reactionRowObjects.map(MappedReactionMessageRow.init(object:)),
        currentUserID: currentUserID,
        accountID: accountID
    )
}

private func expectedEvents(fileName: String) -> [ServerEvent] {
    messageEventFixtures.first { $0.fileName == fileName }?.expected ?? []
}

private func hashedThread(_ id: String) -> String {
    Hasher.thread.tokenizeRemembering(pii: id)
}

private func hashedParticipant(_ id: String) -> String {
    Hasher.participant.tokenizeRemembering(pii: id)
}

private func message(
    id: PlatformSDK.MessageID,
    timestamp: PlatformSDK.Timestamp,
    senderID: PlatformSDK.UserID,
    text: String,
    isHidden: Bool? = nil,
    isAction: Bool? = nil,
    parseTemplate: Bool? = nil,
    linkedMessageID: PlatformSDK.MessageID? = nil,
    action: PlatformSDK.MessageAction? = nil
) -> PlatformSDK.Message {
    PlatformSDK.Message(
        id: id,
        timestamp: timestamp,
        senderID: senderID,
        text: text,
        isHidden: isHidden,
        isAction: isAction,
        parseTemplate: parseTemplate,
        linkedMessageID: linkedMessageID,
        action: action
    )
}

private extension [ServerEvent] {
    var containsMessageDeleteEvent: Bool {
        contains { event in
            let object = event.jsonObject()
            return object["objectName"] as? String == "message"
                && object["mutationType"] as? String == "delete"
        }
    }

    func containPartialServerEvents(_ expected: [ServerEvent]) -> Bool {
        guard count == expected.count else {
            return false
        }
        return zip(self, expected).allSatisfy { actual, expected in
            jsonContains(actual.jsonObject(), expected.jsonObject())
        }
    }
}

private func jsonContains(_ actual: Any, _ expected: Any) -> Bool {
    if let expected = expected as? FixtureJSONObject {
        guard let actual = actual as? FixtureJSONObject else {
            return false
        }
        return expected.allSatisfy { key, value in
            actual[key].map { jsonContains($0, value) } ?? false
        }
    }

    if let expected = expected as? [Any] {
        guard let actual = actual as? [Any], actual.count == expected.count else {
            return false
        }
        return zip(actual, expected).allSatisfy(jsonContains)
    }

    return String(describing: actual) == String(describing: expected)
}
