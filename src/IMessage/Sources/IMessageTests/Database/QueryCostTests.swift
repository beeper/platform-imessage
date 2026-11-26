import Foundation
@testable import IMDatabase
import Testing

private typealias Synthetic = SyntheticChatDatabase

/// One database query and the most SQLite steps it may take on the synthetic
/// database. Budgets are a few times the measured cost, far below what a scan
/// of the 200,000-row message table costs, so a query that loses its index or
/// starts scaling with the unread backlog fails here.
private struct QueryCase: Sendable {
    let name: String
    let budget: Int
    /// Set where the cost grows with the unread backlog instead of staying flat.
    let heavyUnreadBudget: Int?
    let run: @Sendable (IMDatabase) throws -> Void

    init(_ name: String, budget: Int, heavyUnreadBudget: Int? = nil, _ run: @escaping @Sendable (IMDatabase) throws -> Void) {
        self.name = name
        self.budget = budget
        self.heavyUnreadBudget = heavyUnreadBudget
        self.run = run
    }

    func budget(for variant: Synthetic.Variant) -> Int {
        variant.unread == .heavy ? heavyUnreadBudget ?? budget : budget
    }
}

private let count = Synthetic.messageCount
private let hugeChat = Synthetic.chatGUID(Synthetic.hugeChatRowID)
private let smallChat = Synthetic.chatGUID(Synthetic.smallChatRowID)
/// The 25 chats a first thread-list page would hold.
private let pageChatRowIDs = Array(1 ... 25)
/// A page of recent messages in the huge chat (every tenth row belongs to it).
private let recentHugeChatRowIDs = Array(stride(from: count - 400, to: count - 200, by: 10))
private let recentHugeChatGUIDs = recentHugeChatRowIDs.map(Synthetic.messageGUID)
private let oldHugeChatGUIDs = stride(from: 1000, to: 1200, by: 10).map(Synthetic.messageGUID)

private let queryCases: [QueryCase] = [
    // Thread list
    QueryCase("mappedThreadRows first page", budget: 80_000) { _ = try $0.mappedThreadRows(cursor: nil, direction: nil) },
    QueryCase("mappedThreadRows next page", budget: 30_000) {
        _ = try $0.mappedThreadRows(cursor: String(Synthetic.messageDate(count - 2000)), direction: .before)
    },
    QueryCase("mappedThreadRow", budget: 2_000) { _ = try $0.mappedThreadRow(guid: smallChat) },
    QueryCase("mappedExistingChatGUIDs", budget: 2_000) {
        _ = try $0.mappedExistingChatGUIDs(guids: pageChatRowIDs.map(Synthetic.chatGUID))
    },
    QueryCase("mappedThreadParticipantRows page", budget: 3_000) { _ = try $0.mappedThreadParticipantRows(chatRowIDs: pageChatRowIDs) },
    QueryCase("mappedLatestMessageRows page", budget: 30_000) { _ = try $0.mappedLatestMessageRows(chatRowIDs: pageChatRowIDs) },
    QueryCase("mappedUnreadCounts page", budget: 7_000, heavyUnreadBudget: 2_000_000) { _ = try $0.mappedUnreadCounts(chatRowIDs: pageChatRowIDs) },
    QueryCase("mappedUnreadCounts one small chat", budget: 3_000, heavyUnreadBudget: 800_000) {
        _ = try $0.mappedUnreadCounts(chatRowIDs: [Synthetic.smallChatRowID])
    },
    QueryCase("mappedUnreadCounts huge chat", budget: 4_000, heavyUnreadBudget: 1_000_000) { _ = try $0.mappedUnreadCounts(chatRowIDs: [Synthetic.hugeChatRowID]) },
    QueryCase("isThreadRead huge chat", budget: 2_000) { _ = try $0.isThreadRead(chatGUID: hugeChat) },
    QueryCase("chatStates", budget: 40_000) { _ = try $0.chatStates() },
    QueryCase("chats", budget: 10_000) { _ = try $0.chats() },
    QueryCase("chat(withGUID:)", budget: 2_000) { _ = try $0.chat(withGUID: smallChat) },
    QueryCase("handles(inChatWithGUID:)", budget: 2_000) { _ = try $0.handles(inChatWithGUID: hugeChat) },
    QueryCase("allThreadGUIDs", budget: 5_000) { _ = try $0.allThreadGUIDs() },
    QueryCase("accountLogins", budget: 5_000) { _ = try $0.accountLogins() },

    // Message pages
    QueryCase("mappedMessageRows latest page, huge chat", budget: 20_000) {
        _ = try $0.mappedMessageRows(in: hugeChat, cursor: nil, direction: nil)
    },
    QueryCase("mappedMessageRows before cursor, huge chat", budget: 20_000) {
        _ = try $0.mappedMessageRows(in: hugeChat, cursor: String(Synthetic.messageDate(count / 2)), direction: .before)
    },
    QueryCase("mappedMessageRows after cursor, huge chat", budget: 30_000) {
        _ = try $0.mappedMessageRows(in: hugeChat, cursor: String(Synthetic.messageDate(count - 300)), direction: .after)
    },
    QueryCase("mappedMessageRows by GUID", budget: 20_000) { _ = try $0.mappedMessageRows(guids: recentHugeChatGUIDs) },
    QueryCase("mappedMessageRows by row ID", budget: 30_000) { _ = try $0.mappedMessageRows(rowIDs: recentHugeChatRowIDs) },
    QueryCase("mappedMessageRow", budget: 2_000) { _ = try $0.mappedMessageRow(guid: Synthetic.messageGUID(count / 2)) },
    QueryCase("existingMessageGUIDs", budget: 2_000) { _ = try $0.existingMessageGUIDs(among: recentHugeChatGUIDs) },
    QueryCase("mappedChatRowID", budget: 2_000) { _ = try $0.mappedChatRowID(guid: smallChat) },
    QueryCase("threadIDForMessage", budget: 2_000) { _ = try $0.threadIDForMessage(rowID: count / 2) },
    QueryCase("mappedLatestVisibleMessageRow all chats", budget: 2_000) { _ = try $0.mappedLatestVisibleMessageRow(offset: 3) },
    QueryCase("mappedLatestVisibleMessageRow all chats, owned", budget: 2_000) {
        _ = try $0.mappedLatestVisibleMessageRow(offset: 3, ownedOnly: true)
    },
    QueryCase("mappedLatestVisibleMessageRow huge chat", budget: 2_000) {
        _ = try $0.mappedLatestVisibleMessageRow(in: hugeChat, offset: 3)
    },
    QueryCase("message(with:)", budget: 2_000) { _ = try $0.message(with: GUID(Synthetic.messageGUID(count / 2))) },
    QueryCase("messages(in:) huge chat", budget: 20_000) { _ = try $0.messages(in: GUID(hugeChat)) },
    QueryCase("messages(in:) small chat", budget: 2_000) { _ = try $0.messages(in: GUID(smallChat)) },
    QueryCase("messages(in:) before a date, small chat", budget: 2_000) {
        _ = try $0.messages(in: GUID(smallChat), filter: .before(nanosecondsSinceReferenceDate: Int64(Synthetic.messageDate(count / 2))))
    },
    QueryCase("messages(in:) after a date, huge chat", budget: 20_000) {
        _ = try $0.messages(
            in: GUID(hugeChat),
            filter: .after(nanosecondsSinceReferenceDate: Int64(Synthetic.messageDate(count / 2))),
            order: .oldestFirst
        )
    },

    // Reactions and attachments
    QueryCase("mappedReactionRows recent page, huge chat", budget: 50_000) {
        _ = try $0.mappedReactionRows(messageGUIDs: recentHugeChatGUIDs, chatRowIDs: [Synthetic.hugeChatRowID])
    },
    QueryCase("mappedReactionRows old page, huge chat", budget: 2_500_000) {
        _ = try $0.mappedReactionRows(messageGUIDs: oldHugeChatGUIDs, chatRowIDs: [Synthetic.hugeChatRowID])
    },
    QueryCase("mappedAttachmentRows", budget: 3_000) { _ = try $0.mappedAttachmentRows(messageRowIDs: recentHugeChatRowIDs) },
    QueryCase("attachmentFilename by GUID", budget: 2_000) { _ = try $0.attachmentFilename(guid: "att-\(count - 22)") },
    QueryCase("attachmentFilename by message", budget: 2_000) { _ = try $0.attachmentFilename(messageRowID: count - 22) },
    QueryCase("digitalTouchPayload", budget: 2_000) { _ = try $0.digitalTouchPayload(rowID: count / 2) },
    QueryCase("handwritingPayload", budget: 2_000) { _ = try $0.handwritingPayload(rowID: count / 2) },

    // Polling
    QueryCase("lastMessageRowID", budget: 2_000) { _ = try $0.lastMessageRowID() },
    QueryCase("messageUpdateCursorSnapshot", budget: 2_000) { _ = try $0.messageUpdateCursorSnapshot() },
    QueryCase("messages(since:) nothing new", budget: 2_000) {
        let snapshot = try $0.messageUpdateCursorSnapshot()
        _ = try $0.messages(since: snapshot)
    },
    QueryCase("sentMessageIDs", budget: 2_000) { _ = try $0.sentMessageIDs(since: count - 50) },
    QueryCase("recentDestinationCallerIDs", budget: 2_000) {
        _ = try $0.recentDestinationCallerIDs(withinNanoseconds: 3600 * 1_000_000_000)
    },

    // Search reads message text, so its cost is the number of rows it has to look at.
    QueryCase("searchMessages common word, all chats", budget: 3_000) { _ = try $0.searchMessages(query: "lorem") },
    QueryCase("searchMessages rare word, all chats", budget: 400_000) { _ = try $0.searchMessages(query: "needle") },
    QueryCase("searchMessages rare word, huge chat", budget: 200_000) { _ = try $0.searchMessages(query: "needle", chatGUID: hugeChat) },
    QueryCase("searchMessages rare word, small chat", budget: 2_000) { _ = try $0.searchMessages(query: "needle", chatGUID: smallChat) },
]

@Test(arguments: Synthetic.variants)
private func queriesStayWithinTheirStepBudget(variant: Synthetic.Variant) throws {
    let database = try Synthetic.shared(variant).imDatabase
    let printsReport = ProcessInfo.processInfo.environment["QUERY_COST_REPORT"] == "1"
    for queryCase in queryCases {
        // The first run prepares and caches the statement; measure the second.
        try queryCase.run(database)
        let start = Date()
        let steps = try database.countingSteps { try queryCase.run(database) }
        if printsReport {
            let milliseconds = String(format: "%.2f", Date().timeIntervalSince(start) * 1000)
            print("COST\t\(variant)\t\(queryCase.name)\t\(steps)\t\(milliseconds)")
        }
        let budget = queryCase.budget(for: variant)
        #expect(steps <= budget, "\(queryCase.name) took \(steps) steps on \(variant), budget \(budget)")
    }
}

/// Queries that take no budget: they run no SQL of their own, only touch
/// schema metadata, or are covered through the query they wrap.
private let functionsWithoutACase: Set = [
    "tableColumns", "hasRecoverableMessageJoin", "cachedStatement", "hydrateAttachments",
    "findClosestSelectablePart", "findFirstSelectablePart", "searchMessageRowIDs",
    "before", "after", "merging",
    "beginListeningForChanges", "stopListeningForChanges", "makeWatcher", "createIndexesIfNecessary",
]

@Test func everyDatabaseQueryHasACostCase() throws {
    let queryDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("IMDatabase/Database")
    let declaration = try NSRegularExpression(pattern: #"^\s*(?:(?:public|package|static|nonisolated)\s+)*func (\w+)"#, options: .anchorsMatchLines)
    var uncovered = Set<String>()
    for file in try FileManager.default.contentsOfDirectory(at: queryDirectory, includingPropertiesForKeys: nil) {
        let source = try String(contentsOf: file, encoding: .utf8)
        for match in declaration.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let name = String(source[Range(match.range(at: 1), in: source)!])
            if !functionsWithoutACase.contains(name), !queryCases.contains(where: { $0.name.hasPrefix(name) }) {
                uncovered.insert(name)
            }
        }
    }
    #expect(uncovered.isEmpty, "add a QueryCase (or an exemption) for: \(uncovered.sorted())")
}
