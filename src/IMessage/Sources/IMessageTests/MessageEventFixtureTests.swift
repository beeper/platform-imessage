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
}

private let directThreadID = hashedThread("any;-;+15557654321")
private let groupThreadID = hashedThread("any;+;chat27499326783338645")
private let jobsThreadID = hashedThread("any;-;sjobs@apple.com")
private let jobsParticipantID = hashedParticipant("sjobs@apple.com")
private let phoneParticipantID = hashedParticipant("+15557654321")
// `heart` is the Platform SDK key for the iMessage heart tapback; desktop renders
// it as ❤️ via supportedReactions, but state-sync delete IDs use reactionKey.
private let heartReactionKey = "heart"

private let messageEventFixtures = [
    MessageEventFixture(
        fileName: "message_event_edited",
        change: .edited,
        expected: [
            .updateMessages(threadID: directThreadID, patches: [[
                "id": "994ABD79-CD14-439F-856A-4F40A97C7A1F",
                "text": "edited test",
            ]]),
        ]
    ),
    MessageEventFixture(
        fileName: "message_event_new_incoming",
        change: .new,
        expected: [
            .upsertMessages(threadID: groupThreadID, messages: [
                message(
                    id: "258F5823-789D-446B-BDE7-DF7335B4F3FA",
                    timestamp: 1_777_979_134_036,
                    senderID: phoneParticipantID,
                    text: "yes"
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
                    id: "F84C284B-0E3B-4004-88EC-30BB7C97ED41",
                    timestamp: 1_777_967_368_566,
                    senderID: jobsParticipantID,
                    text: "test outgoing"
                ),
            ]),
        ]
    ),
    MessageEventFixture(
        fileName: "message_event_reaction_add",
        change: .new,
        expected: [
            .upsertMessageReactions(
                threadID: jobsThreadID,
                messageID: "346FFDC8-11A7-47B8-9879-5DEB56A6F199",
                reactions: [
                    PlatformSDK.MessageReaction(
                        id: jobsParticipantID,
                        reactionKey: "like",
                        participantID: jobsParticipantID
                    ),
                ]
            ),
            .upsertMessages(
                threadID: jobsThreadID,
                messages: [
                    message(
                        id: "06FC451C-4E1A-4411-9DBA-BF1005E0AD2C",
                        timestamp: 1_777_978_860_327,
                        senderID: jobsParticipantID,
                        text: "You liked a message",
                        isHidden: true,
                        isAction: true,
                        parseTemplate: true,
                        linkedMessageID: "346FFDC8-11A7-47B8-9879-5DEB56A6F199",
                        action: .messageReactionCreated(PlatformSDK.PartialMessageReactionAction(
                            messageID: "346FFDC8-11A7-47B8-9879-5DEB56A6F199",
                            reactionKey: "like",
                            participantID: "sjobs@apple.com"
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
                messageID: "EFA8FBDE-A18F-44D9-966F-019DEB5E3571",
                ids: ["\(phoneParticipantID)\(heartReactionKey)"]
            ),
            .upsertMessages(
                threadID: directThreadID,
                messages: [
                    message(
                        id: "44C2A47F-F39C-4B16-9FC3-AC8DA915DBA3",
                        timestamp: 1_777_486_996_739,
                        senderID: phoneParticipantID,
                        text: "{{sender}} removed a heart from a message",
                        isHidden: true,
                        isAction: true,
                        parseTemplate: true,
                        linkedMessageID: "EFA8FBDE-A18F-44D9-966F-019DEB5E3571",
                        action: .messageReactionDeleted(PlatformSDK.PartialMessageReactionAction(
                            messageID: "EFA8FBDE-A18F-44D9-966F-019DEB5E3571",
                            reactionKey: "heart",
                            participantID: "+15557654321"
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
                "id": "B6C7FCF4-6038-4AD7-977B-B19230D1033B",
                "text": "{{sender}} unsent a message",
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
