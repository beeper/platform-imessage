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
            "262F0210-126B-40E1-8247-C3EECF585C66",
            "262F0210-126B-40E1-8247-C3EECF585C66_1",
            "262F0210-126B-40E1-8247-C3EECF585C66_2",
            "262F0210-126B-40E1-8247-C3EECF585C66_3",
        ],
        texts: [nil, "1", nil, "2"],
        attachmentCounts: [1, 0, 1, 0],
        reactionCounts: [1, 1, 1, 1]
    ),
    MapperFixture(
        fileName: "message_multipart_incoming_with_attachments",
        messageIDs: [
            "829D7284-F1C6-4848-B7C7-C4190EA416BD",
            "829D7284-F1C6-4848-B7C7-C4190EA416BD_1",
            "829D7284-F1C6-4848-B7C7-C4190EA416BD_2",
            "829D7284-F1C6-4848-B7C7-C4190EA416BD_3",
            "829D7284-F1C6-4848-B7C7-C4190EA416BD_4",
        ],
        texts: ["part 0", nil, "part 2", nil, "part 4"],
        attachmentCounts: [0, 1, 0, 1, 0],
        reactionCounts: [0, 0, 0, 1, 1]
    ),
    MapperFixture(
        fileName: "message_partial_leading_unsends",
        messageIDs: [
            "B51D6CD9-86B6-4D1B-856F-2DA152A9F8A0",
            "B51D6CD9-86B6-4D1B-856F-2DA152A9F8A0_1",
            "B51D6CD9-86B6-4D1B-856F-2DA152A9F8A0_2",
        ],
        texts: ["a", "{{sender}} unsent a message", "{{sender}} unsent a message"],
        attachmentCounts: [0, 0, 0],
        reactionCounts: [0, 0, 0]
    ),
    MapperFixture(
        fileName: "message_partial_multiple_middle_adjacent_unsends",
        messageIDs: [
            "3BC3F988-3263-4200-9863-8EBD537FE7EB",
            "3BC3F988-3263-4200-9863-8EBD537FE7EB_1",
            "3BC3F988-3263-4200-9863-8EBD537FE7EB_2",
        ],
        texts: [
            "begin middle multiple adjacent unsendend middle multiple adjacent unsend",
            "{{sender}} unsent a message",
            "{{sender}} unsent a message",
        ],
        attachmentCounts: [0, 0, 0],
        reactionCounts: [0, 0, 0]
    ),
    MapperFixture(
        fileName: "message_partial_trailing_unsends",
        messageIDs: [
            "FE617A4A-D6C3-42F8-8006-DACEF68FDEF1",
            "FE617A4A-D6C3-42F8-8006-DACEF68FDEF1_1",
            "FE617A4A-D6C3-42F8-8006-DACEF68FDEF1_2",
        ],
        texts: ["a", "{{sender}} unsent a message", "{{sender}} unsent a message"],
        attachmentCounts: [0, 0, 0],
        reactionCounts: [0, 0, 0]
    ),
]

@Test(arguments: mapperFixtures)
private func messageMapperFixture(fixture: MapperFixture) throws {
    let values = try loadFixture(fixture.fileName)
    #expect(values.count == 5)

    let msgRow = try #require(values[0] as? FixtureJSONObject)
    let attachmentRows = try #require(values[1] as? [FixtureJSONObject])
    let reactionRows = try #require(values[2] as? [FixtureJSONObject])
    let currentUserID = try #require(values[3] as? String)
    let accountID = try #require(values[4] as? String)

    let messages = try Mapper(
        msgRow: msgRow,
        attachmentRows: attachmentRows,
        reactionRows: reactionRows,
        currentUserID: currentUserID,
        accountID: accountID
    ).mapMessage()

    #expect(messages.map(\.id) == fixture.messageIDs)
    #expect(messages.map(\.text) == fixture.texts)
    #expect(messages.map { $0.attachments?.count ?? 0 } == fixture.attachmentCounts)
    #expect(messages.map { $0.reactions?.count ?? 0 } == fixture.reactionCounts)
}

@Test
private func stickerAssociatedMessagePreservesLinkedMessageID() throws {
    let messages = try Mapper(
        msgRow: [
            "ROWID": 1,
            "guid": "STICKER-GUID",
            "dateString": "1",
            "date": "1",
            "is_from_me": 0,
            "handle_id": 1,
            "participantID": "sender",
            "item_type": 0,
            "service": "iMessage",
            "threadID": "iMessage;+;chat",
            "associated_message_guid": "p:0/TARGET-GUID",
            "associated_message_type": 1000,
        ],
        attachmentRows: [[
            "msgRowID": 1,
            "attachmentID": "ATTACHMENT-GUID",
            "transfer_state": 5,
            "fileName": "sticker.heic",
            "filePath": "/tmp/sticker.heic",
            "ext": "heic",
            "total_bytes": 10,
        ]],
        reactionRows: [],
        currentUserID: "me",
        accountID: "default"
    ).mapMessage()

    let message = try #require(messages.first)
    #expect(messages.count == 1)
    #expect(message.linkedMessageID == "TARGET-GUID")
    #expect(message.attachments?.count == 1)
}

@Test
private func findMyPayloadMessageMapsAsLocation() throws {
    let messages = try Mapper(
        msgRow: [
            "ROWID": 1,
            "guid": "FINDMY-GUID",
            "date": "1",
            "text": imessageExtensionCharacter,
            "is_from_me": 1,
            "handle_id": 0,
            "item_type": 0,
            "service": "iMessage",
            "threadID": "iMessage;+;chat",
            "balloon_bundle_id": BalloonBundleID.findMy,
            "payload_data": findMyPayloadData(latitude: 12.34, longitude: 56.78),
        ],
        attachmentRows: [],
        reactionRows: [],
        currentUserID: "me",
        accountID: "default"
    ).mapMessage()

    let message = try #require(messages.first)
    let extra = try #require(message.extra as? FixtureJSONObject)
    let location = try #require(extra["location"] as? FixtureJSONObject)

    #expect(messages.count == 1)
    #expect(message.textHeading == "Find My")
    #expect(message.textFooter == "Started Sharing Location")
    #expect(extra["type"] as? String == "LOCATION")
    #expect(location["latitude"] as? Double == 12.34)
    #expect(location["longitude"] as? Double == 56.78)
}

@Test(arguments: [true, false])
private func pollPayloadMessageMapsAsReadableSummary(isFromMe: Bool) throws {
    let message = try pollPayloadMessage(isFromMe: isFromMe)

    #expect(message.textHeading == "Poll")
    #expect(message.textFooter == nil)
    #expect(message.text == "Lunch?\n\n1. Pizza\n2. Sushi")
    #expect(message.isAction == nil)
    #expect(message.parseTemplate == nil)
}

@Test
private func pollSentAssociatedMessageMapsAsAction() throws {
    let outgoing = try pollSentAssociatedMessage(isFromMe: true)
    let incoming = try pollSentAssociatedMessage(isFromMe: false)

    #expect(outgoing.text == "You sent a poll")
    #expect(outgoing.textHeading == nil)
    #expect(outgoing.linkedMessageID == "POLL-SENT-GUID")
    #expect(outgoing.isAction == true)
    #expect(outgoing.isHidden == nil)
    #expect(outgoing.parseTemplate == true)

    #expect(incoming.text == "{{sender}} sent a poll")
    #expect(incoming.textHeading == nil)
    #expect(incoming.linkedMessageID == "POLL-SENT-GUID")
    #expect(incoming.isAction == true)
    #expect(incoming.isHidden == nil)
    #expect(incoming.parseTemplate == true)
}

@Test
private func pollVoteAssociatedMessageMapsAsHiddenAction() throws {
    let message = try singleMappedMessage(from: [
        "ROWID": 2,
        "guid": "POLL-VOTE-GUID",
        "date": "2",
        "text": " ",
        "is_from_me": 1,
        "handle_id": 0,
        "item_type": 0,
        "service": "iMessage",
        "threadID": "iMessage;+;chat",
        "associated_message_guid": "POLL-GUID",
        "associated_message_type": 4000,
        "balloon_bundle_id": BalloonBundleID.polls,
        "payload_data": pollVotePayloadData(optionIDs: ["OPTION-1"]),
    ])

    #expect(message.text == "You voted in a poll")
    #expect(message.textHeading == nil)
    #expect(message.linkedMessageID == "POLL-GUID")
    #expect(message.isAction == true)
    #expect(message.isHidden == true)
}

@Test
private func gamePigeonMessagesUsePayloadHeadingAndUpdateCaption() throws {
    let message = try gamePigeonAssociatedMessage(isFromMe: true)
    let update = try gamePigeonAssociatedUpdateMessage(isFromMe: false)
    let invite = try gamePigeonIncomingInviteMessage()
    let fallback = try gamePigeonAssociatedMessageWithoutPayload(isFromMe: true)

    #expect(message.text == "Word Hunt")
    #expect(message.textHeading == "GamePigeon: Word Hunt")
    #expect(message.textFooter == "Your move.")
    #expect(message.linkedMessageID == "GAME-GUID")
    #expect(message.isAction == nil)
    #expect(message.parseTemplate == true)

    #expect(update.text == "")
    #expect(update.textHeading == "GamePigeon: Word Hunt")
    #expect(update.textFooter == "I won!")
    #expect(update.linkedMessageID == "GAME-GUID")
    #expect(update.isAction == nil)
    #expect(update.parseTemplate == nil)

    #expect(invite.text == "Anagrams")
    #expect(invite.textHeading == "GamePigeon: Anagrams")
    #expect(invite.textFooter == "Let's play Anagrams!")
    #expect(invite.linkedMessageID == "ANAGRAMS-GUID")
    #expect(invite.isAction == nil)
    #expect(invite.parseTemplate == true)

    #expect(fallback.text == "Word Hunt")
    #expect(fallback.textHeading == "GamePigeon")
    #expect(fallback.textFooter == nil)
    #expect(fallback.linkedMessageID == "GAME-GUID")
    #expect(fallback.isAction == nil)
    #expect(fallback.parseTemplate == true)
}

@Test
private func unsupportedExtensionMessageMapsAsActionPlaceholder() throws {
    let outgoing = try unsupportedExtensionMessage(isFromMe: true)
    let incoming = try unsupportedExtensionMessage(isFromMe: false)

    #expect(outgoing.text == "You sent a message from Mystery App")
    #expect(outgoing.textHeading == nil)
    #expect(outgoing.linkedMessageID == "UNKNOWN-GUID")
    #expect(outgoing.isAction == true)
    #expect(outgoing.parseTemplate == true)

    #expect(incoming.text == "{{sender}} sent a message from Mystery App")
    #expect(incoming.textHeading == nil)
    #expect(incoming.linkedMessageID == "UNKNOWN-GUID")
    #expect(incoming.isAction == true)
    #expect(incoming.parseTemplate == true)
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

private func findMyPayloadData(latitude: Double, longitude: Double) throws -> Data {
    let json = try JSONSerialization.data(withJSONObject: [
        "initialLocation": [
            "latitude": latitude,
            "longitude": longitude,
        ],
    ])
    let zippedData = try (json as NSData).compressed(using: .zlib).base64EncodedString()
    return try NSKeyedArchiver.archivedData(
        withRootObject: [
            "an": "Find My",
            "ldtext": "Started Sharing Location",
            "URL": try findMyPayloadURL(zippedData: zippedData),
        ] as NSDictionary,
        requiringSecureCoding: false
    )
}

private func findMyPayloadURL(zippedData: String) throws -> String {
    var components = URLComponents()
    components.queryItems = [
        URLQueryItem(name: "FindMyMessagePayloadVersionKey", value: "v0"),
        URLQueryItem(name: "FindMyMessagePayloadZippedDataKey", value: zippedData),
    ]
    return try #require(components.string)
}

private func pollPayloadData(title: String, options: [String]) throws -> Data {
    let pollOptions: [FixtureJSONObject] = options.enumerated().map { index, option in
        [
            "optionIdentifier": "OPTION-\(index + 1)",
            "text": option,
            "attributedText": option,
            "canBeEdited": false,
            "creatorHandle": "sender",
        ]
    }
    let json = try JSONSerialization.data(withJSONObject: [
        "item": [
            "title": title,
            "orderedPollOptions": pollOptions,
            "creatorHandle": "sender",
        ],
        "version": 1,
    ])
    return try NSKeyedArchiver.archivedData(
        withRootObject: [
            "an": "Polls",
            "ldtext": "Sent a poll",
            "URL": "data:,\(json.base64EncodedString())?src=p&c=\(options.count)",
        ] as NSDictionary,
        requiringSecureCoding: false
    )
}

private func pollPayloadMessage(isFromMe: Bool) throws -> PlatformSDK.Message {
    var msgRow: FixtureJSONObject = [
        "ROWID": 1,
        "guid": isFromMe ? "POLL-GUID" : "INCOMING-POLL-GUID",
        "date": "1",
        "text": imessageExtensionCharacter,
        "is_from_me": isFromMe ? 1 : 0,
        "handle_id": isFromMe ? 0 : 1,
        "item_type": 0,
        "service": "iMessage",
        "threadID": "iMessage;+;chat",
        "balloon_bundle_id": BalloonBundleID.polls,
        "payload_data": try pollPayloadData(title: "Lunch?", options: ["Pizza", "Sushi"]),
    ]
    if !isFromMe {
        msgRow["participantID"] = "sender"
    }

    return try singleMappedMessage(from: msgRow)
}

private func pollSentAssociatedMessage(isFromMe: Bool) throws -> PlatformSDK.Message {
    let rowID = isFromMe ? outgoingPollSentRowID : incomingPollSentRowID
    return try singleMappedMessage(
        from: [
            "ROWID": rowID,
            "guid": "POLL-SENT-GUID",
            "date": "2",
            "text": "Sent a poll",
            "is_from_me": isFromMe ? 1 : 0,
            "handle_id": isFromMe ? 0 : 1,
            "participantID": "sender",
            "item_type": 0,
            "service": "iMessage",
            "threadID": "iMessage;+;chat",
            "associated_message_guid": "POLL-SENT-GUID",
            "associated_message_type": 3,
            "balloon_bundle_id": BalloonBundleID.polls,
            "payload_data": pollPayloadData(title: "Lunch?", options: ["Pizza", "Sushi"]),
        ]
    )
}

private func pollVotePayloadData(optionIDs: [String]) throws -> Data {
    let votes: [FixtureJSONObject] = optionIDs.map { optionID in
        [
            "participantHandle": "sender",
            "voteOptionIdentifier": optionID,
        ]
    }
    let json = try JSONSerialization.data(withJSONObject: [
        "item": [
            "votes": votes,
        ],
        "version": 1,
    ])
    return try NSKeyedArchiver.archivedData(
        withRootObject: [
            "an": "Polls",
            "URL": "data:,\(json.base64EncodedString())",
        ] as NSDictionary,
        requiringSecureCoding: false
    )
}

private func unsupportedExtensionPayloadData(appName: String) throws -> Data {
    try NSKeyedArchiver.archivedData(
        withRootObject: [
            "an": appName,
            "ldtext": "Unsupported payload",
        ] as NSDictionary,
        requiringSecureCoding: false
    )
}

private func gamePigeonAssociatedMessage(isFromMe: Bool) throws -> PlatformSDK.Message {
    try singleMappedMessage(
        from: iMessageAppMessageRow(
            rowID: 6,
            guid: "GAMEPIGEON-GUID-\(isFromMe)",
            date: "4",
            text: "Word Hunt",
            isFromMe: isFromMe,
            associatedMessageGUID: "GAME-GUID",
            associatedMessageType: 3,
            balloonBundleID: BalloonBundleID.gamePigeon,
            payloadData: gamePigeonPayloadData(game: "Word Hunt", caption: "Your move.")
        )
    )
}

private func gamePigeonIncomingInviteMessage() throws -> PlatformSDK.Message {
    try singleMappedMessage(
        from: iMessageAppMessageRow(
            rowID: 8,
            guid: "GAMEPIGEON-ANAGRAMS-GUID",
            date: "6",
            text: "Anagrams",
            isFromMe: false,
            associatedMessageGUID: "ANAGRAMS-GUID",
            associatedMessageType: 3,
            balloonBundleID: BalloonBundleID.gamePigeon,
            payloadData: gamePigeonPayloadData(game: "Anagrams", caption: "Let's play Anagrams!")
        )
    )
}

private func gamePigeonAssociatedMessageWithoutPayload(isFromMe: Bool) throws -> PlatformSDK.Message {
    try singleMappedMessage(
        from: iMessageAppMessageRow(
            rowID: 9,
            guid: "GAMEPIGEON-NO-PAYLOAD-GUID-\(isFromMe)",
            date: "7",
            text: "Word Hunt",
            isFromMe: isFromMe,
            associatedMessageGUID: "GAME-GUID",
            associatedMessageType: 3,
            balloonBundleID: BalloonBundleID.gamePigeon
        )
    )
}

private func gamePigeonPayloadData(game: String, caption: String) throws -> Data {
    try NSKeyedArchiver.archivedData(
        withRootObject: [
            "an": "GamePigeon",
            "ldtext": game,
            "userInfo": [
                "caption": caption,
            ] as NSDictionary,
        ] as NSDictionary,
        requiringSecureCoding: false
    )
}

private func gamePigeonAssociatedUpdateMessage(isFromMe: Bool) throws -> PlatformSDK.Message {
    try singleMappedMessage(
        from: iMessageAppMessageRow(
            rowID: 7,
            guid: "GAMEPIGEON-UPDATE-GUID-\(isFromMe)",
            date: "5",
            text: imessageExtensionCharacter,
            isFromMe: isFromMe,
            associatedMessageGUID: "GAME-GUID",
            associatedMessageType: 2,
            balloonBundleID: BalloonBundleID.gamePigeon,
            payloadData: gamePigeonPayloadData(game: "Word Hunt", caption: "I won!")
        )
    )
}

private func unsupportedExtensionMessage(isFromMe: Bool) throws -> PlatformSDK.Message {
    try singleMappedMessage(
        from: iMessageAppMessageRow(
            rowID: isFromMe ? 4 : 5,
            guid: "UNSUPPORTED-GUID",
            date: "3",
            text: imessageExtensionCharacter,
            isFromMe: isFromMe,
            associatedMessageGUID: "UNKNOWN-GUID",
            associatedMessageType: 2,
            balloonBundleID: "com.example.Mystery.MessagesExtension",
            payloadData: unsupportedExtensionPayloadData(appName: "Mystery App")
        )
    )
}

private func iMessageAppMessageRow(
    rowID: Int,
    guid: String,
    date: String,
    text: String,
    isFromMe: Bool,
    associatedMessageGUID: String,
    associatedMessageType: Int,
    balloonBundleID: String,
    payloadData: Data? = nil
) -> FixtureJSONObject {
    var row: FixtureJSONObject = [
        "ROWID": rowID,
        "guid": guid,
        "date": date,
        "text": text,
        "is_from_me": isFromMe ? 1 : 0,
        "handle_id": isFromMe ? 0 : 1,
        "participantID": "sender",
        "item_type": 0,
        "service": "iMessage",
        "threadID": "iMessage;+;chat",
        "associated_message_guid": associatedMessageGUID,
        "associated_message_type": associatedMessageType,
        "balloon_bundle_id": balloonBundleID,
    ]
    if let payloadData {
        row["payload_data"] = payloadData
    }
    return row
}

private let incomingPollSentRowID = 2
private let outgoingPollSentRowID = 3

private func singleMappedMessage(from msgRow: FixtureJSONObject) throws -> PlatformSDK.Message {
    let messages = try Mapper(
        msgRow: msgRow,
        attachmentRows: [],
        reactionRows: [],
        currentUserID: "me",
        accountID: "default"
    ).mapMessage()

    #expect(messages.count == 1)
    return try #require(messages.first)
}
