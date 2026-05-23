import Foundation
import SQLite

package struct MessageSearchResult {
    package let rowIDs: [Int]
    package let hasMore: Bool
    /// Compound `"date,rowID"` cursor for fetching the next page of *older* matches (`.before`).
    package let oldestCursor: String?
    /// Compound `"date,rowID"` cursor for fetching the next page of *newer* matches (`.after`).
    package let newestCursor: String?
}

extension IMDatabase {
    /// Searches messages by text content, properly decoding attributedBody.
    /// Returns ROWIDs of matching messages that can be used to fetch full message data.
    /// - Parameters:
    ///   - query: The search term (case-insensitive)
    ///   - chatGUID: Optional chat GUID to filter messages by conversation
    ///   - mediaOnly: If true, only return messages with attachments
    ///   - sender: Optional sender filter - "me" for sent messages, "others" for received messages
    ///   - cursor: Optional compound `"date,rowID"` message cursor to page before or after
    ///   - direction: Whether the cursor should fetch older (`before`) or newer (`after`) matches
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of ROWIDs for messages that match the search query
    public func searchMessages(
        query: String,
        chatGUID: String? = nil,
        mediaOnly: Bool = false,
        sender: String? = nil,
        cursor: String? = nil,
        direction: MappedPageDirection? = nil,
        limit: Int = 20
    ) throws -> [Int] {
        try searchMessageRowIDs(
            query: query,
            chatGUID: chatGUID,
            mediaOnly: mediaOnly,
            sender: sender,
            cursor: cursor,
            direction: direction,
            limit: limit
        ).rowIDs
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Search pagination                                                         │
    // │                                                                           │
    // │ attributedBody is a binary NSArchiver blob, so the match predicate can't  │
    // │ live in SQL. We stream rows in (date, ROWID) order, decode + substring-   │
    // │ match each in Swift, and stop as soon as we have limit+1 matches (the     │
    // │ extra one is a lookahead that yields an accurate `hasMore` without being  │
    // │ returned). A scan cap bounds the worst case: a rare/no-hit query would    │
    // │ otherwise decode every message in the database.                           │
    // │                                                                           │
    // │   .before / no cursor → ORDER BY date DESC, ROWID DESC  (newest first)    │
    // │   .after  (+ cursor)  → ORDER BY date ASC,  ROWID ASC   (oldest-of-newer) │
    // │                                                                           │
    // │ Cursors are compound "date,rowID" so equal-date matches paginate without  │
    // │ skips/duplicates. On a cap-hit with fewer than limit+1 matches, hasMore   │
    // │ stays true and the continuation cursor is the last *scanned* row (not the │
    // │ last *returned* match) so the next page resumes past the scanned window.  │
    // └─────────────────────────────────────────────────────────────────────────┘
    package func searchMessageRowIDs(
        query: String,
        chatGUID: String? = nil,
        mediaOnly: Bool = false,
        sender: String? = nil,
        cursor: String? = nil,
        direction: MappedPageDirection? = nil,
        limit: Int = 20
    ) throws -> MessageSearchResult {
        guard limit > 0 else {
            return MessageSearchResult(rowIDs: [], hasMore: false, oldestCursor: nil, newestCursor: nil)
        }

        let queryLower = query.lowercased()
        let parsedCursor = cursor.flatMap(Self.parseSearchCursor)
        let effectiveDirection = parsedCursor != nil ? (direction ?? .before) : .before
        let isAscending = effectiveDirection == .after
        let comparisonOperator = isAscending ? ">" : "<"
        let orderDirection = isAscending ? "ASC" : "DESC"
        let matchLimit = limit == Int.max ? limit : limit + 1
        let scanCap = limit == Int.max ? Int.max : limit * 200

        // Build SQL query with optional filters
        var sql = """
        SELECT m.ROWID, m.date, m.text, m.attributedBody
        FROM message m
        """

        // Add chat join if filtering by chatGUID
        if chatGUID != nil {
            sql += """

            LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
            """
        }

        sql += """

        WHERE (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
        """

        if chatGUID != nil {
            sql += "\nAND t.guid = ?"
        }
        if mediaOnly {
            sql += "\nAND m.cache_has_attachments = 1"
        }
        if sender == "me" {
            sql += "\nAND m.is_from_me = 1"
        } else if sender == "others" {
            sql += "\nAND m.is_from_me = 0"
        }
        if parsedCursor != nil {
            // Stable compound comparison so equal-date matches aren't skipped.
            sql += "\nAND (m.date \(comparisonOperator) ? OR (m.date = ? AND m.ROWID \(comparisonOperator) ?))"
        }

        sql += """

        ORDER BY m.date \(orderDirection), m.ROWID \(orderDirection)
        """

        let statement = try cachedStatement(forEscapedSQL: sql).reset()

        // Bind parameters in declaration order: chatGUID, then cursor bounds.
        var params: [any SQLiteBindable] = []
        if let chatGUID {
            params.append(chatGUID)
        }
        if let parsedCursor {
            params.append(parsedCursor.date)
            params.append(parsedCursor.date)
            params.append(parsedCursor.rowID)
        }
        if !params.isEmpty {
            try statement.bind(params)
        }

        var matched: [(rowID: Int, date: Int)] = []
        var lastScanned: (rowID: Int, date: Int)?
        var scanned = 0
        var capHit = false

        try statement.stepUntilStopped(handlingRows: { row in
            scanned += 1
            let rowID = try row[0].expect(Int.self)
            let date = try row[1].optional(Int.self) ?? 0
            lastScanned = (rowID: rowID, date: date)

            let plainText = try row[2].optional(String.self)
            let attributedBodyData = try row[3].optional(Data.self)

            // Try to get text from attributedBody first (more complete), fall back to text column
            var messageText: String?

            if let data = attributedBodyData {
                messageText = try? AttributedBodyDecoder.plainText(from: data)
            }

            // Fall back to plain text column
            if messageText == nil || messageText?.isEmpty == true {
                messageText = plainText
            }

            // Check if the decoded text actually contains the search query (case-insensitive)
            if let text = messageText, text.lowercased().contains(queryLower) {
                matched.append((rowID: rowID, date: date))
                if matched.count >= matchLimit {
                    return false
                }
            }

            // Bound the worst case: stop scanning once we've examined scanCap candidates.
            if scanned >= scanCap {
                capHit = true
                return false
            }

            return true
        })

        let returned = Array(matched.prefix(limit))
        let foundMore = matched.count > limit
        // More results exist either via the lookahead match, or because the cap
        // truncated the scan before we could prove there were none.
        let hasMore = foundMore || capHit

        var oldestCursor = Self.searchCursorString(returned.min(by: Self.searchOrderAscending))
        var newestCursor = Self.searchCursorString(returned.max(by: Self.searchOrderAscending))

        // On a cap-hit without a full lookahead, resume from the last *scanned*
        // candidate so the next page doesn't rescan the same window (and so an
        // all-non-match page still hands back a usable continuation cursor).
        if capHit, !foundMore, let lastScanned {
            let continuation = Self.searchCursorString(lastScanned)
            if isAscending {
                newestCursor = continuation
            } else {
                oldestCursor = continuation
            }
        }

        return MessageSearchResult(
            rowIDs: returned.map(\.rowID),
            hasMore: hasMore,
            oldestCursor: oldestCursor,
            newestCursor: newestCursor
        )
    }

    /// Parses a compound `"date,rowID"` cursor. Returns `nil` for any input that isn't
    /// a well-formed pair (treated as no cursor) — search only ever emits this format.
    private static func parseSearchCursor(_ cursor: String) -> (date: Int, rowID: Int)? {
        let parts = cursor.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let date = Int(parts[0]), let rowID = Int(parts[1]) else { return nil }
        return (date: date, rowID: rowID)
    }

    private static func searchCursorString(_ row: (rowID: Int, date: Int)?) -> String? {
        guard let row else { return nil }
        return "\(row.date),\(row.rowID)"
    }

    /// Lexicographic `(date, rowID)` ordering, matching the SQL `ORDER BY date, ROWID`.
    private static func searchOrderAscending(_ lhs: (rowID: Int, date: Int), _ rhs: (rowID: Int, date: Int)) -> Bool {
        (lhs.date, lhs.rowID) < (rhs.date, rhs.rowID)
    }
}
