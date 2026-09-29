@testable import IMessage
import Testing

@Test func addressesReferToSameRecipientMatchesFormattingVariants() {
    #expect(addressesReferToSameRecipient("+15035550123", "+15035550123"))
    #expect(addressesReferToSameRecipient("+15035550123", "5035550123"))
    #expect(addressesReferToSameRecipient("5035550123", "+1 (503) 555-0123"))
    #expect(addressesReferToSameRecipient("a@example.com", "A@Example.com"))
}

@Test func addressesReferToSameRecipientRejectsDifferentRecipients() {
    #expect(!addressesReferToSameRecipient("+15035550123", "+15035550124"))
    #expect(!addressesReferToSameRecipient("a@example.com", "b@example.com"))
    // emails must match exactly, not by digit content
    #expect(!addressesReferToSameRecipient("5550123@example.com", "5550123"))
    // shortcodes may not tail-match a full number
    #expect(!addressesReferToSameRecipient("50123", "+15035550123"))
    #expect(!addressesReferToSameRecipient(nil, "+15035550123"))
    #expect(!addressesReferToSameRecipient("", ""))
}

private let sentMessage = (rowID: 1, guid: "AAAAAAAA-0000-0000-0000-000000000001")
private let otherSentMessage = (rowID: 2, guid: "AAAAAAAA-0000-0000-0000-000000000002")

@Test func validSentMessageIDsAcceptsExactThreadMatch() {
    let valid = PlatformAPI.validSentMessageIDs(
        targetThreadID: "iMessage;-;+15035550123",
        sentMessageIDs: [sentMessage],
        sentThreadIDs: ["iMessage;-;+15035550123"],
        isSameContact: { _, _ in false }
    )
    #expect(valid.map(\.rowID) == [1])
}

@Test func validSentMessageIDsAcceptsServiceAndFormattingFlips() {
    // same recipient under a different service or handle formatting must not
    // require the contacts database (DESK-28166: isSameContact false-negative
    // left the client's echo stuck on "still sending")
    let valid = PlatformAPI.validSentMessageIDs(
        targetThreadID: "iMessage;-;+15035550123",
        sentMessageIDs: [sentMessage],
        sentThreadIDs: ["SMS;-;5035550123"],
        isSameContact: { _, _ in false }
    )
    #expect(valid.map(\.rowID) == [1])
}

@Test func validSentMessageIDsFallsBackToContacts() {
    let valid = PlatformAPI.validSentMessageIDs(
        targetThreadID: "iMessage;-;a@example.com",
        sentMessageIDs: [sentMessage],
        sentThreadIDs: ["iMessage;-;+15035550123"],
        isSameContact: { a, b in a == "a@example.com" && b == "+15035550123" }
    )
    #expect(valid.map(\.rowID) == [1])
}

@Test func validSentMessageIDsDropsForeignRowsIndividually() {
    // a concurrent send to somebody else must not discard the whole batch
    let valid = PlatformAPI.validSentMessageIDs(
        targetThreadID: "iMessage;-;+15035550123",
        sentMessageIDs: [sentMessage, otherSentMessage],
        sentThreadIDs: ["iMessage;-;+15035550123", "iMessage;-;+19995550000"],
        isSameContact: { _, _ in false }
    )
    #expect(valid.map(\.rowID) == [1])
}

@Test func validSentMessageIDsDropsUnjoinedRows() {
    let valid = PlatformAPI.validSentMessageIDs(
        targetThreadID: "iMessage;-;+15035550123",
        sentMessageIDs: [sentMessage, otherSentMessage],
        sentThreadIDs: [nil, "iMessage;-;+15035550123"],
        isSameContact: { _, _ in false }
    )
    #expect(valid.map(\.rowID) == [2])
}

@Test func validSentMessageIDsReturnsEmptyWhenNothingMatches() {
    let valid = PlatformAPI.validSentMessageIDs(
        targetThreadID: "iMessage;-;+15035550123",
        sentMessageIDs: [sentMessage],
        sentThreadIDs: ["iMessage;-;+19995550000"],
        isSameContact: { _, _ in false }
    )
    #expect(valid.isEmpty)
}
