import Foundation
@testable import IMessage
import PlatformSDK
import Testing

private struct MapperFixture: Sendable {
    let fileName: String
    let messageIDs: [String]
    let texts: [String?]
    let attachmentCounts: [Int]
    let reactionCounts: [Int]
}

private let mapperFixtures = [
    MapperFixture(
        fileName: "message_multipart_outgoing_with_reactions",
        messageIDs: [
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000001_1",
            "00000000-0000-4000-8000-000000000001_2",
            "00000000-0000-4000-8000-000000000001_3",
        ],
        texts: [nil, "fixture part one", nil, "fixture part two"],
        attachmentCounts: [1, 0, 1, 0],
        reactionCounts: [1, 1, 1, 1]
    ),
    MapperFixture(
        fileName: "message_multipart_incoming_with_attachments",
        messageIDs: [
            "00000000-0000-4000-8000-000000000002",
            "00000000-0000-4000-8000-000000000002_1",
            "00000000-0000-4000-8000-000000000002_2",
            "00000000-0000-4000-8000-000000000002_3",
            "00000000-0000-4000-8000-000000000002_4",
        ],
        texts: ["fixture first", nil, "fixture second", nil, "fixture third"],
        attachmentCounts: [0, 1, 0, 1, 0],
        reactionCounts: [0, 0, 0, 1, 1]
    ),
    MapperFixture(
        fileName: "message_partial_leading_unsends",
        messageIDs: [
            "00000000-0000-4000-8000-000000000003",
            "00000000-0000-4000-8000-000000000003_1",
            "00000000-0000-4000-8000-000000000003_2",
        ],
        texts: ["fixture kept", "{{sender}} unsent a message", "{{sender}} unsent a message"],
        attachmentCounts: [0, 0, 0],
        reactionCounts: [0, 0, 0]
    ),
    MapperFixture(
        fileName: "message_partial_multiple_middle_adjacent_unsends",
        messageIDs: [
            "00000000-0000-4000-8000-000000000004",
            "00000000-0000-4000-8000-000000000004_1",
            "00000000-0000-4000-8000-000000000004_2",
            "00000000-0000-4000-8000-000000000004_3",
        ],
        texts: [
            "fixture begin",
            "{{sender}} unsent a message",
            "{{sender}} unsent a message",
            "fixture end",
        ],
        attachmentCounts: [0, 0, 0, 0],
        reactionCounts: [0, 0, 0, 0]
    ),
    MapperFixture(
        fileName: "message_partial_trailing_unsends",
        messageIDs: [
            "00000000-0000-4000-8000-000000000005",
            "00000000-0000-4000-8000-000000000005_1",
            "00000000-0000-4000-8000-000000000005_2",
        ],
        texts: ["fixture kept", "{{sender}} unsent a message", "{{sender}} unsent a message"],
        attachmentCounts: [0, 0, 0],
        reactionCounts: [0, 0, 0]
    ),
]

@Test(arguments: mapperFixtures)
private func messageMapperFixture(fixture: MapperFixture) throws {
    let messages = try mappedFixtureMessages(fixture.fileName)

    #expect(messages.map(\.id) == fixture.messageIDs)
    #expect(messages.map(\.text) == fixture.texts)
    #expect(messages.map { $0.attachments?.count ?? 0 } == fixture.attachmentCounts)
    #expect(messages.map { $0.reactions?.count ?? 0 } == fixture.reactionCounts)
}

@Test
private func stickerAssociatedMessagePreservesLinkedMessageID() throws {
    let messages = try mappedFixtureMessages("message_sticker_associated")
    let message = try #require(messages.first)

    #expect(messages.count == 1)
    #expect(message.linkedMessageID == "00000000-0000-4000-8000-000000000015")
    #expect(message.attachments?.count == 1)
}

@Test
private func findMyPayloadMessageMapsAsLocation() throws {
    let message = try mappedFixtureMessage("message_findmy_payload")
    let extra = try #require(message.extra as? FixtureJSONObject)
    let location = try #require(extra["location"] as? FixtureJSONObject)

    #expect(message.textHeading == "Find My")
    #expect(message.textFooter == "Started Sharing Fixture Location")
    #expect(extra["type"] as? String == "LOCATION")
    #expect(location["latitude"] as? Double == 12.34)
    #expect(location["longitude"] as? Double == 56.78)
}

@Test
private func findMyPayloadIgnoresInfoPlistLocalizationTableHeading() throws {
    var values = try loadFixture("message_findmy_payload")
    let seedPayload = try #require(fixtureMapper(values).payloadData())
    let seedURL = try #require(unwrapDictionary(seedPayload)?["URL"])
    var messageRow = try #require(values[0] as? FixtureJSONObject)
    messageRow["payload_data"] = try NSKeyedArchiver.archivedData(
        withRootObject: [
            "an": "INFO_PLIST_LOCALIZABLE_STRINGS",
            "ldtext": "Started Sharing Fixture Location",
            "URL": seedURL,
        ] as NSDictionary,
        requiringSecureCoding: false
    )
    values[0] = messageRow

    let message = try #require(try mappedFixtureMessages(from: values).first)

    #expect(message.textHeading == "Find My")
    #expect(message.textFooter == "Started Sharing Fixture Location")
}

@Test(arguments: ["message_poll_payload_outgoing", "message_poll_payload_incoming"])
private func pollPayloadMessageMapsAsReadableSummary(fileName: String) throws {
    let message = try mappedFixtureMessage(fileName)

    #expect(message.textHeading == "Poll")
    #expect(message.textFooter == nil)
    #expect(message.text == "Fixture lunch?\n\n1. Fixture pizza\n2. Fixture sushi")
    #expect(message.isAction == nil)
    #expect(message.parseTemplate == nil)
}

@Test
private func brandLogoAssignmentOriginalMapsToNoMessages() throws {
    #expect(try mappedOriginalFixtureMessages("message_brand_logo_assignment").isEmpty)
}

@Test
private func editedMessageMapsEditHistory() throws {
    var values = try loadFixture("message_event_edited")
    var messageRow = try #require(values[0] as? FixtureJSONObject)
    let originalValues = try loadFixture("message_event_new_outgoing")
    let originalRow = try #require(originalValues[0] as? FixtureJSONObject)
    let originalBody = try #require(originalRow["attributedBody"] as? Data)
    messageRow["message_summary_info"] = try PropertyListSerialization.data(
        fromPropertyList: [
            "otr": ["0": "fixture"],
            "ec": [
                "0": [
                    [
                        "d": 1,
                        "t": originalBody,
                    ],
                ],
            ],
        ],
        format: .binary,
        options: 0
    )
    values[0] = messageRow

    let attachmentRows = try #require(values[1] as? [FixtureJSONObject])
    let reactionRows = try #require(values[2] as? [FixtureJSONObject])
    let currentUserID = try #require(values[3] as? String)
    let accountID = try #require(values[4] as? String)
    let message = try #require(try Mapper(
        messageRow: messageRow,
        attachmentRows: attachmentRows,
        reactionRows: reactionRows,
        currentUserID: currentUserID,
        accountID: accountID
    ).mapMessage().first)

    let edit = try #require(message.editHistory?.first)
    #expect(edit.timestamp == 978_307_201_000)
    #expect(edit.text == "outgoing fixture")
}

@Test
private func editedMessageDropsMalformedEditTimestamp() throws {
    var values = try loadFixture("message_event_edited")
    var messageRow = try #require(values[0] as? FixtureJSONObject)
    let originalValues = try loadFixture("message_event_new_outgoing")
    let originalRow = try #require(originalValues[0] as? FixtureJSONObject)
    let originalBody = try #require(originalRow["attributedBody"] as? Data)
    messageRow["message_summary_info"] = try PropertyListSerialization.data(
        fromPropertyList: [
            "otr": ["0": "fixture"],
            "ec": [
                "0": [
                    [
                        "d": Int.max,
                        "t": originalBody,
                    ],
                    [
                        "d": 1,
                        "t": originalBody,
                    ],
                ],
            ],
        ],
        format: .binary,
        options: 0
    )
    values[0] = messageRow

    let attachmentRows = try #require(values[1] as? [FixtureJSONObject])
    let reactionRows = try #require(values[2] as? [FixtureJSONObject])
    let currentUserID = try #require(values[3] as? String)
    let accountID = try #require(values[4] as? String)
    let message = try #require(try Mapper(
        messageRow: messageRow,
        attachmentRows: attachmentRows,
        reactionRows: reactionRows,
        currentUserID: currentUserID,
        accountID: accountID
    ).mapMessage().first)

    let editHistory = try #require(message.editHistory)
    #expect(editHistory.map(\.timestamp) == [978_307_201_000])
}

@Test
private func editedMessageExcludesCurrentMessageFromEditHistory() throws {
    var values = try loadFixture("message_event_edited")
    var messageRow = try #require(values[0] as? FixtureJSONObject)
    let editedBody = try #require(messageRow["attributedBody"] as? Data)
    let originalValues = try loadFixture("message_event_new_outgoing")
    let originalRow = try #require(originalValues[0] as? FixtureJSONObject)
    let originalBody = try #require(originalRow["attributedBody"] as? Data)
    messageRow["message_summary_info"] = try PropertyListSerialization.data(
        fromPropertyList: [
            "otr": ["0": "fixture"],
            "ec": [
                "0": [
                    [
                        "d": 1,
                        "t": originalBody,
                    ],
                    [
                        "d": 721_693_160,
                        "t": editedBody,
                    ],
                ],
            ],
        ],
        format: .binary,
        options: 0
    )
    values[0] = messageRow

    let attachmentRows = try #require(values[1] as? [FixtureJSONObject])
    let reactionRows = try #require(values[2] as? [FixtureJSONObject])
    let currentUserID = try #require(values[3] as? String)
    let accountID = try #require(values[4] as? String)
    let message = try #require(try Mapper(
        messageRow: messageRow,
        attachmentRows: attachmentRows,
        reactionRows: reactionRows,
        currentUserID: currentUserID,
        accountID: accountID
    ).mapMessage().first)

    let editHistory = try #require(message.editHistory)
    #expect(editHistory.map(\.text) == ["outgoing fixture"])
}

@Test
private func multipartEditHistoryDoesNotBleedIntoNextOutputPart() throws {
    var values = try loadFixture("message_multipart_outgoing_with_reactions")
    var messageRow = try #require(values[0] as? FixtureJSONObject)
    let editedValues = try loadFixture("message_event_edited")
    let editedRow = try #require(editedValues[0] as? FixtureJSONObject)
    let editedBody = try #require(editedRow["attributedBody"] as? Data)
    messageRow["message_summary_info"] = try PropertyListSerialization.data(
        fromPropertyList: [
            "ec": [
                "0": [
                    [
                        "d": 1,
                        "t": editedBody,
                    ],
                ],
            ],
        ],
        format: .binary,
        options: 0
    )
    values[0] = messageRow

    let attachmentRows = try #require(values[1] as? [FixtureJSONObject])
    let reactionRows = try #require(values[2] as? [FixtureJSONObject])
    let currentUserID = try #require(values[3] as? String)
    let accountID = try #require(values[4] as? String)
    let messages = try Mapper(
        messageRow: messageRow,
        attachmentRows: attachmentRows,
        reactionRows: reactionRows,
        currentUserID: currentUserID,
        accountID: accountID
    ).mapMessage()

    #expect(messages.count == 4)
    #expect(messages[0].editHistory?.map(\.timestamp) == [978_307_201_000])
    #expect(messages[1].editHistory == nil)
}

@Test
private func multipartEditedTimestampOnlyAppliesToEditedPart() throws {
    let messages = try mappedFixtureMessages("message_multipart_outgoing_edited_caption")

    #expect(messages.map(\.editedTimestamp) == [nil, 1_780_045_129_945])
    #expect(messages.map(\.text) == [nil, "fixture caption text!!"])
    #expect(messages[1].editHistory?.map(\.text) == ["fixture caption text??"])
}

@Test
private func pollSentAssociatedMessageMapsAsAction() throws {
    let outgoing = try mappedFixtureMessage("message_poll_sent_outgoing")
    let incoming = try mappedFixtureMessage("message_poll_sent_incoming")

    #expect(outgoing.text == "You sent a poll")
    #expect(outgoing.textHeading == nil)
    #expect(outgoing.linkedMessageID == "00000000-0000-4000-8000-000000000022")
    #expect(outgoing.isAction == true)
    #expect(outgoing.isHidden == nil)
    #expect(outgoing.parseTemplate == true)

    #expect(incoming.text == "{{sender}} sent a poll")
    #expect(incoming.textHeading == nil)
    #expect(incoming.linkedMessageID == "00000000-0000-4000-8000-000000000022")
    #expect(incoming.isAction == true)
    #expect(incoming.isHidden == nil)
    #expect(incoming.parseTemplate == true)
}

@Test
private func pollVoteAssociatedMessageMapsAsHiddenAction() throws {
    let message = try mappedFixtureMessage("message_poll_vote")

    #expect(message.text == "You voted in a poll")
    #expect(message.textHeading == nil)
    #expect(message.linkedMessageID == "00000000-0000-4000-8000-000000000024")
    #expect(message.isAction == true)
    #expect(message.isHidden == true)
}

@Test
private func gamePigeonMessagesUsePayloadHeadingAndUpdateCaption() throws {
    let message = try mappedFixtureMessage("message_gamepigeon_associated")
    let update = try mappedFixtureMessage("message_gamepigeon_update")
    let invite = try mappedFixtureMessage("message_gamepigeon_invite")
    let fallback = try mappedFixtureMessage("message_gamepigeon_fallback")

    #expect(message.text == "Fixture Word Hunt")
    #expect(message.textHeading == "GamePigeon: Fixture Word Hunt")
    #expect(message.textFooter == "Fixture move.")
    #expect(message.linkedMessageID == "00000000-0000-4000-8000-000000000028")
    #expect(message.isAction == nil)
    #expect(message.parseTemplate == true)

    #expect(update.text == "")
    #expect(update.textHeading == "GamePigeon: Fixture Word Hunt")
    #expect(update.textFooter == "Fixture won.")
    #expect(update.linkedMessageID == "00000000-0000-4000-8000-000000000028")
    #expect(update.isAction == nil)
    #expect(update.parseTemplate == nil)

    #expect(invite.text == "Fixture Anagrams")
    #expect(invite.textHeading == "GamePigeon: Fixture Anagrams")
    #expect(invite.textFooter == "Fixture invite.")
    #expect(invite.linkedMessageID == "00000000-0000-4000-8000-000000000031")
    #expect(invite.isAction == nil)
    #expect(invite.parseTemplate == true)

    #expect(fallback.text == "Fixture Word Hunt")
    #expect(fallback.textHeading == "GamePigeon")
    #expect(fallback.textFooter == nil)
    #expect(fallback.linkedMessageID == "00000000-0000-4000-8000-000000000028")
    #expect(fallback.isAction == nil)
    #expect(fallback.parseTemplate == true)
}

@Test
private func unsupportedExtensionMessageMapsAsActionPlaceholder() throws {
    let outgoing = try mappedFixtureMessage("message_unsupported_extension_outgoing")
    let incoming = try mappedFixtureMessage("message_unsupported_extension_incoming")
    let outgoingExtra = try #require(outgoing.extra as? FixtureJSONObject)
    let incomingExtra = try #require(incoming.extra as? FixtureJSONObject)

    #expect(outgoing.text == "You sent a message from Fixture App")
    #expect(outgoing.textHeading == nil)
    #expect(outgoing.linkedMessageID == "00000000-0000-4000-8000-000000000035")
    #expect(outgoing.isAction == true)
    #expect(outgoing.parseTemplate == true)
    #expect(outgoingExtra["canReply"] as? Bool == false)

    #expect(incoming.text == "{{sender}} sent a message from Fixture App")
    #expect(incoming.textHeading == nil)
    #expect(incoming.linkedMessageID == "00000000-0000-4000-8000-000000000035")
    #expect(incoming.isAction == true)
    #expect(incoming.parseTemplate == true)
    #expect(incomingExtra["canReply"] as? Bool == false)
}

@Test
private func urlBalloonMessageKeepsLinkOnlyContent() throws {
    let message = try mappedFixtureMessage("message_url_balloon")
    let link = try #require(message.links?.first)
    let extra = try #require(message.extra as? FixtureJSONObject)

    #expect(message.links?.count == 1)
    #expect(link.url == "https://fixture.example.invalid/link")
    #expect(link.title == "Fixture Link")
    #expect(extra["canReply"] == nil)
}

@Test
private func digitalTouchMessageDropsWhitespacePlaceholderText() throws {
    let message = try mappedFixtureMessage("message_digital_touch")
    let attachment = try #require(message.attachments?.first)
    let extra = try #require(message.extra as? FixtureJSONObject)

    #expect(message.text == nil)
    #expect(message.textHeading == "Digital Touch Message")
    #expect(attachment.id == "4BED3FC2-0A9D-43BD-926C-4C5078465350")
    #expect(attachment.srcURL == "asset://$accountID/dt/4BED3FC2-0A9D-43BD-926C-4C5078465350.10027.mov")
    #expect(extra["canReply"] as? Bool == false)
}

@Test
private func platformSDKJSONObjectMacroSerializesWireShape() throws {
    let attachment = PlatformSDK.Attachment(
        id: "attachment-id",
        type: .img,
        size: PlatformSDK.Size(width: 100, height: 200),
        srcURL: "asset://attachment"
    )
    let message = PlatformSDK.Message(
        id: "message-id",
        timestamp: 1,
        senderID: "sender-id",
        attachments: [attachment],
        behavior: .keepRead
    )

    let messageObject = message.jsonObject
    #expect(messageObject["_original"] == nil)
    #expect(messageObject["behavior"] as? String == "keep_read")
    let attachments = try #require(messageObject["attachments"] as? [FixtureJSONObject])
    #expect(attachments.first?["type"] as? String == "img")
    #expect((attachments.first?["size"] as? FixtureJSONObject)?["width"] as? Double == 100)

    let thread = PlatformSDK.Thread(
        id: "thread-id",
        isUnread: false,
        isReadOnly: false,
        type: .group,
        messages: PlatformSDK.Paginated(items: [message], hasMore: false),
        participants: PlatformSDK.Paginated(items: [], hasMore: false)
    )
    let threadObject = thread.jsonObject
    #expect(threadObject["_original"] == nil)
    #expect(threadObject["type"] as? String == "group")
    #expect((threadObject["messages"] as? FixtureJSONObject)?["hasMore"] as? Bool == false)
}

private func mappedFixtureMessage(_ fileName: String) throws -> PlatformSDK.Message {
    let messages = try mappedFixtureMessages(fileName)
    #expect(messages.count == 1)
    return try #require(messages.first)
}

private func mappedFixtureMessages(_ fileName: String) throws -> [PlatformSDK.Message] {
    let values = try loadFixture(fileName)
    return try mappedFixtureMessages(from: values)
}

private func mappedFixtureMessages(from values: [Any]) throws -> [PlatformSDK.Message] {
    try fixtureMapper(values).mapMessage()
}

private func mappedOriginalFixtureMessages(_ fileName: String) throws -> [PlatformSDK.Message] {
    let original = try loadFixture(fileName)
    #expect(original.count == 3)
    let messageRow = try #require(original[0] as? FixtureJSONObject)
    let attachmentRows = try #require(original[1] as? [FixtureJSONObject])
    let currentUserID = try #require(original[2] as? String)

    return try Mapper(
        messageRow: messageRow,
        attachmentRows: attachmentRows,
        reactionRows: [],
        currentUserID: currentUserID,
        accountID: "fixture-imessage-account"
    ).mapMessage()
}

private func fixtureMapper(_ values: [Any]) throws -> Mapper {
    #expect(values.count == 5)

    let messageRow = try #require(values[0] as? FixtureJSONObject)
    let attachmentRows = try #require(values[1] as? [FixtureJSONObject])
    let reactionRows = try #require(values[2] as? [FixtureJSONObject])
    let currentUserID = try #require(values[3] as? String)
    let accountID = try #require(values[4] as? String)

    return try Mapper(
        messageRow: messageRow,
        attachmentRows: attachmentRows,
        reactionRows: reactionRows,
        currentUserID: currentUserID,
        accountID: accountID
    )
}
