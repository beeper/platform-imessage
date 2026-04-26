import Foundation
@testable import SwiftServer
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
        fileName: "fixture1",
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
        fileName: "fixture2",
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
        fileName: "partial_leading_unsends",
        messageIDs: [
            "B51D6CD9-86B6-4D1B-856F-2DA152A9F8A0",
            "B51D6CD9-86B6-4D1B-856F-2DA152A9F8A0_1",
            "B51D6CD9-86B6-4D1B-856F-2DA152A9F8A0_2",
        ],
        texts: ["{{sender}} unsent a message", "{{sender}} unsent a message", "a"],
        attachmentCounts: [0, 0, 0],
        reactionCounts: [0, 0, 0]
    ),
    MapperFixture(
        fileName: "partial_multiple_middle_adjacent_unsend",
        messageIDs: [
            "3BC3F988-3263-4200-9863-8EBD537FE7EB",
            "3BC3F988-3263-4200-9863-8EBD537FE7EB_1",
            "3BC3F988-3263-4200-9863-8EBD537FE7EB_2",
            "3BC3F988-3263-4200-9863-8EBD537FE7EB_3",
        ],
        texts: [
            "begin middle multiple adjacent unsend",
            "{{sender}} unsent a message",
            "{{sender}} unsent a message",
            "end middle multiple adjacent unsend",
        ],
        attachmentCounts: [0, 0, 0, 0],
        reactionCounts: [0, 0, 0, 0]
    ),
    MapperFixture(
        fileName: "partial_trailing_unsends",
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

    let msgRow = try #require(values[0] as? JSONObject)
    let attachmentRows = try #require(values[1] as? [JSONObject])
    let reactionRows = try #require(values[2] as? [JSONObject])
    let currentUserID = try #require(values[3] as? String)
    let accountID = try #require(values[4] as? String)

    let messages = try Mapper(
        msgRow: msgRow,
        attachmentRows: attachmentRows,
        reactionRows: reactionRows,
        currentUserID: currentUserID,
        accountID: accountID
    ).mapMessage()

    #expect(messages.map { $0.string("id") } == fixture.messageIDs)
    #expect(messages.map { $0.string("text") } == fixture.texts)
    #expect(messages.map { ($0["attachments"] as? [JSONObject])?.count ?? 0 } == fixture.attachmentCounts)
    #expect(messages.map { ($0["reactions"] as? [JSONObject])?.count ?? 0 } == fixture.reactionCounts)
}

private func loadFixture(_ name: String) throws -> [Any] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [Any])
}
