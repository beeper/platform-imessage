import Foundation
import GRDB

public extension IMDatabase {
    /// Searches messages by text content, properly decoding attributedBody.
    /// Returns ROWIDs of matching messages that can be used to fetch full message data.
    /// - Parameters:
    ///   - query: The search term (case-insensitive)
    ///   - chatGUID: Optional chat GUID to filter messages by conversation
    ///   - mediaOnly: If true, only return messages with attachments
    ///   - sender: Optional sender filter - "me" for sent messages, "others" for received messages
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of ROWIDs for messages that match the search query
    func searchMessages(
        query: String,
        chatGUID: String? = nil,
        mediaOnly: Bool = false,
        sender: String? = nil,
        limit: Int = 20
    ) throws -> [Int] {
        let queryLower = query.lowercased()

        // Build SQL query with optional filters
        var sql = """
        SELECT m.ROWID, m.text, m.attributedBody
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

        sql += """

        ORDER BY m.date DESC
        LIMIT ?
        """

        // Fetch more than limit to account for filtering - we'll filter in Swift after decoding
        let fetchLimit = limit * 20

        var matchingRowIDs: [Int] = []
        let arguments = chatGUID.map { sqlArguments([$0, fetchLimit]) } ?? StatementArguments([fetchLimit])

        try read { db in
            let cursor = try fetchCursorRowsCached(db: db, sql: sql, arguments: arguments)
            while let row = try cursor.next() {
                // Stop once we have enough results
                guard matchingRowIDs.count < limit else { break }

                let rowID = row.requiredInt(at: 0)
                let plainText = row.optionalString(at: 1)
                let attributedBodyData = row.optionalData(at: 2)

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
                guard let text = messageText, text.lowercased().contains(queryLower) else {
                    continue
                }

                matchingRowIDs.append(rowID)
            }
        }

        return matchingRowIDs
    }
}
