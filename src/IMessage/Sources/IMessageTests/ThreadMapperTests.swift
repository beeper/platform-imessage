@testable import IMessage
import Testing

private let lastReadAppleDate = 100_000_000_000
private let latestMessageAppleDate = 200_000_000_000

@Test func readChatReportsNewestMessageAsReadPosition() {
    let sortKey = ThreadMapper.lastReadMessageSortKey(
        lastReadMessageTimestamp: lastReadAppleDate,
        latestMessageDate: latestMessageAppleDate,
        unreadCount: 0
    )
    #expect(sortKey == appleDateMilliseconds(latestMessageAppleDate))
}

@Test func unreadChatKeepsMessagesReadPosition() {
    let sortKey = ThreadMapper.lastReadMessageSortKey(
        lastReadMessageTimestamp: lastReadAppleDate,
        latestMessageDate: latestMessageAppleDate,
        unreadCount: 2
    )
    #expect(sortKey == appleDateMilliseconds(lastReadAppleDate))
}

@Test func readChatNeverMovesReadPositionBackwards() {
    let sortKey = ThreadMapper.lastReadMessageSortKey(
        lastReadMessageTimestamp: latestMessageAppleDate,
        latestMessageDate: lastReadAppleDate,
        unreadCount: 0
    )
    #expect(sortKey == appleDateMilliseconds(latestMessageAppleDate))
}

@Test func readChatWithoutReadTimestampUsesNewestMessage() {
    let sortKey = ThreadMapper.lastReadMessageSortKey(
        lastReadMessageTimestamp: nil,
        latestMessageDate: latestMessageAppleDate,
        unreadCount: 0
    )
    #expect(sortKey == appleDateMilliseconds(latestMessageAppleDate))
}
