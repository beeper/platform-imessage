import IMDatabase
@testable import IMessage
import Testing

@Test func searchMessagesFindsMatchesPastInitialCandidateWindow() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 1, text: "the buried project status update")
    try fixture.insertFillerMessages(rowIDs: 2 ... 402)

    let matchingRowIDs = try fixture.imDatabase.searchMessages(query: "project status", limit: 20)

    #expect(matchingRowIDs == [1])
}

@Test func platformSearchUsesLookaheadForHasMoreWithoutReturningExtraMessage() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 1, guid: "00000000-0000-4000-8000-000000000101", text: "project status older")
    try fixture.insertMessage(rowID: 2, guid: "00000000-0000-4000-8000-000000000102", text: "project status newer")
    try fixture.insertChatJoin(messageRowID: 1)
    try fixture.insertChatJoin(messageRowID: 2)

    let result = try PlatformAPI.searchMessages(
        db: fixture.imDatabase,
        query: "project status",
        threadID: nil,
        mediaOnly: false,
        sender: nil,
        currentUserID: "fixture-self@example.invalid",
        accountID: "default",
        limit: 1
    )

    #expect(result.items.map(\.id) == ["00000000-0000-4000-8000-000000000102"])
    #expect(result.hasMore)
}

@Test func searchScopedToChatReturnsOnlyThatChatsMatches() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    // Two messages match the query; only one is joined to the fixture's chat.
    try fixture.insertMessage(rowID: 1, text: "project status in chat")
    try fixture.insertMessage(rowID: 2, text: "project status not in chat")
    try fixture.insertChatJoin(messageRowID: 1)

    let matchingRowIDs = try fixture.imDatabase.searchMessages(
        query: "project status",
        chatGUID: fixture.chatGUID,
        limit: 20
    )

    #expect(matchingRowIDs == [1])
}

@Test func searchUnknownChatReturnsEmpty() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 1, text: "project status")
    try fixture.insertChatJoin(messageRowID: 1)

    let matchingRowIDs = try fixture.imDatabase.searchMessages(
        query: "project status",
        chatGUID: "any;-;+15555550199",
        limit: 20
    )

    #expect(matchingRowIDs.isEmpty)
}

@Test func searchScopedToChatPaginatesEqualDateMatchesWithoutSkips() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    // Three same-date matches in the chat: paging must not skip the equal-date boundary.
    for rowID in 1 ... 3 {
        try fixture.insertMessage(rowID: rowID, text: "project status \(rowID)", date: 100)
        try fixture.insertChatJoin(messageRowID: rowID, messageDate: 100)
    }

    let firstPage = try fixture.imDatabase.searchMessageRowIDs(
        query: "project status",
        chatGUID: fixture.chatGUID,
        limit: 2
    )
    #expect(firstPage.rowIDs == [3, 2])
    #expect(firstPage.hasMore)

    let secondPage = try fixture.imDatabase.searchMessageRowIDs(
        query: "project status",
        chatGUID: fixture.chatGUID,
        cursor: firstPage.oldestCursor,
        direction: .before,
        limit: 2
    )
    #expect(secondPage.rowIDs == [1])
    #expect(!secondPage.hasMore)
}

@Test func searchScopedToChatAfterCursorReturnsContiguousNewerMatches() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    // Five ascending-date matches in the chat. Paging `.after` from the middle
    // exercises the ascending cmj.message_date/message_id branch.
    for rowID in 1 ... 5 {
        try fixture.insertMessage(rowID: rowID, text: "project status \(rowID)", date: rowID * 10)
        try fixture.insertChatJoin(messageRowID: rowID, messageDate: rowID * 10)
    }

    let afterPage = try fixture.imDatabase.searchMessageRowIDs(
        query: "project status",
        chatGUID: fixture.chatGUID,
        cursor: "20,2", // matches newer than (date: 20, rowID: 2)
        direction: .after,
        limit: 2
    )

    // Ascending-of-newer: the two oldest matches strictly after the cursor.
    #expect(afterPage.rowIDs == [3, 4])
    #expect(afterPage.hasMore)
}

// MARK: - attributedBody decode path (T4)

@Test func searchMatchesAttributedBodyOnlyMessagePastInitialWindow() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    // text column is empty; the only match lives in the archived attributedBody blob,
    // which can only be found by decoding in Swift — the reason search can't use SQL.
    try fixture.insertMessage(
        rowID: 1,
        text: "",
        attributedBody: TahoeChatDatabaseFixture.attributedBody("the buried project status update")
    )
    try fixture.insertFillerMessages(rowIDs: 2 ... 402)

    let matchingRowIDs = try fixture.imDatabase.searchMessages(query: "project status", limit: 20)

    #expect(matchingRowIDs == [1])
}

// MARK: - hasMore / limit boundaries (T5)

@Test func searchHasMoreFalseWhenExactlyLimitMatches() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 1, text: "project status one")
    try fixture.insertMessage(rowID: 2, text: "project status two")

    let result = try fixture.imDatabase.searchMessageRowIDs(query: "project status", limit: 2)

    #expect(result.rowIDs == [2, 1]) // newest first
    #expect(!result.hasMore) // exactly `limit` matches, the lookahead must not over-report
}

@Test func searchWithNonPositiveLimitReturnsEmpty() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertMessage(rowID: 1, text: "project status")

    let result = try fixture.imDatabase.searchMessageRowIDs(query: "project status", limit: 0)

    #expect(result.rowIDs.isEmpty)
    #expect(!result.hasMore)
}

@Test func searchWithNoMatchesReturnsEmpty() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    try fixture.insertFillerMessages(rowIDs: 1 ... 5)

    let result = try fixture.imDatabase.searchMessageRowIDs(query: "nonexistent", limit: 20)

    #expect(result.rowIDs.isEmpty)
    #expect(!result.hasMore) // scan completed without hitting the cap, so there are genuinely none
    #expect(result.oldestCursor == nil)
}

@Test func searchScanCapExcludesMatchBeyondCapButReportsHasMore() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    // cap = limit * 200 = 200. The lone match sits oldest (rowID 1), behind 201 newer
    // filler rows, so it falls at scan position 202 — beyond the cap.
    try fixture.insertMessage(rowID: 1, text: "the buried project status update")
    try fixture.insertFillerMessages(rowIDs: 2 ... 202)

    let result = try fixture.imDatabase.searchMessageRowIDs(query: "project status", limit: 1)

    #expect(result.rowIDs.isEmpty) // match is past the scan cap
    #expect(result.hasMore) // cap-hit: more may exist deeper
    #expect(result.oldestCursor != nil) // continuation cursor lets the client page past the scanned window
}

// MARK: - direction + compound cursor (T6)

@Test func searchAfterCursorReturnsContiguousNewerMatchesNotNewest() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    for rowID in 1 ... 4 {
        try fixture.insertMessage(rowID: rowID, text: "project status \(rowID)")
    }

    // .after from (date 1, rowID 1): the contiguous next-newer page is [2, 3], NOT the
    // newest [4, 3]. The pre-fix DESC ordering returned the newest and dropped rowID 2.
    let result = try fixture.imDatabase.searchMessageRowIDs(
        query: "project status",
        cursor: "1,1",
        direction: .after,
        limit: 2
    )

    #expect(result.rowIDs == [2, 3])
    #expect(result.hasMore) // rowID 4 is the lookahead
}

@Test func searchPaginatesEqualDateMatchesWithoutSkips() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    // Three matches share one date; the compound (date, ROWID) cursor must page them
    // without skipping the rest of the tied date.
    try fixture.insertMessage(rowID: 1, text: "project status a", date: 100)
    try fixture.insertMessage(rowID: 2, text: "project status b", date: 100)
    try fixture.insertMessage(rowID: 3, text: "project status c", date: 100)

    let page1 = try fixture.imDatabase.searchMessageRowIDs(query: "project status", limit: 2)
    #expect(page1.rowIDs == [3, 2])
    #expect(page1.hasMore)

    let cursor = try #require(page1.oldestCursor)
    let page2 = try fixture.imDatabase.searchMessageRowIDs(
        query: "project status",
        cursor: cursor,
        direction: .before,
        limit: 2
    )
    #expect(page2.rowIDs == [1]) // the third equal-date match, not skipped
    #expect(!page2.hasMore)
}

@Test func searchBeforeThenAfterRoundTripsBoundary() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    for rowID in 1 ... 5 {
        try fixture.insertMessage(rowID: rowID, text: "project status \(rowID)")
    }

    let page1 = try fixture.imDatabase.searchMessageRowIDs(query: "project status", limit: 2)
    #expect(page1.rowIDs == [5, 4])

    let older = try #require(page1.oldestCursor)
    let page2 = try fixture.imDatabase.searchMessageRowIDs(
        query: "project status",
        cursor: older,
        direction: .before,
        limit: 2
    )
    #expect(page2.rowIDs == [3, 2])

    // Paging .after from page2's newest boundary returns the rows we came from.
    let newer = try #require(page2.newestCursor)
    let back = try fixture.imDatabase.searchMessageRowIDs(
        query: "project status",
        cursor: newer,
        direction: .after,
        limit: 2
    )
    #expect(back.rowIDs == [4, 5])
}

@Test func searchCapHitContinuationCursorSurfacesBuriedMatch() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }

    // The match sits oldest (rowID 1), behind 201 newer filler rows, so it falls at scan
    // position 202 — past the cap (limit * 200 = 200). Page 1 returns nothing but a
    // continuation cursor; feeding that cursor back must reach the buried match without
    // rescanning the already-scanned window. This is the mechanism `hasMore` relies on:
    // an empty cap-hit page is only correct if the continuation actually pages deeper.
    try fixture.insertMessage(rowID: 1, text: "the buried project status update")
    try fixture.insertFillerMessages(rowIDs: 2 ... 202)

    let page1 = try fixture.imDatabase.searchMessageRowIDs(query: "project status", limit: 1)
    #expect(page1.rowIDs.isEmpty) // match is past the scan cap
    #expect(page1.hasMore) // cap-hit: keep paging
    let cursor = try #require(page1.oldestCursor) // continuation past the scanned window

    let page2 = try fixture.imDatabase.searchMessageRowIDs(
        query: "project status",
        cursor: cursor,
        direction: .before,
        limit: 1
    )
    #expect(page2.rowIDs == [1]) // continuation reached the buried match — no skip, no rescan
    #expect(!page2.hasMore) // scan completed under the cap, so there are genuinely no more
}
