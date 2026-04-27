import ExceptionCatcher
import Foundation
import SQLite
import IMessageCore

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
        var sql: String
        if chatGUID != nil {
            sql = """
            SELECT m.ROWID, m.text, m.attributedBody
            FROM chat AS t
            INNER JOIN chat_message_join AS cmj ON cmj.chat_id = t.ROWID
            INNER JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE t.guid = ?
            AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
            """
        } else {
            sql = """
            SELECT m.ROWID, m.text, m.attributedBody
            FROM message AS m
            WHERE (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
            """
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

        ORDER BY \(chatGUID == nil ? "m.date DESC, m.ROWID DESC" : "cmj.message_date DESC, cmj.message_id DESC")
        LIMIT ?
        """

        // Fetch more than limit to account for filtering - we'll filter in Swift after decoding
        let fetchLimit = limit * 20

        let statement = try cachedStatement(forEscapedSQL: sql).reset()

        // Bind parameters in order
        if let chatGUID {
            try statement.bind(chatGUID, fetchLimit)
        } else {
            try statement.bind(fetchLimit)
        }

        var matchingRowIDs: [Int] = []

        try statement.stepUntilDone { row in
            // Stop once we have enough results
            guard matchingRowIDs.count < limit else { return }

            let rowID = try row[0].expect(Int.self)
            let plainText = try row[1].optional(String.self)
            let attributedBodyData = try row[2].optional(Data.self)

            // Try to get text from attributedBody first (more complete), fall back to text column
            var messageText: String?

            if let data = attributedBodyData,
               let unarchiver = NSUnarchiver(forReadingWith: data),
               let decoded = try? ExceptionCatcher.catch(callback: { unarchiver.decodeObject() }),
               let attributedString = decoded as? NSAttributedString {
                messageText = attributedString.string
            }

            // Fall back to plain text column
            if messageText == nil || messageText?.isEmpty == true {
                messageText = plainText
            }

            // Check if the decoded text actually contains the search query (case-insensitive)
            guard let text = messageText, text.lowercased().contains(queryLower) else {
                return
            }

            matchingRowIDs.append(rowID)
        }

        return matchingRowIDs
    }
}
