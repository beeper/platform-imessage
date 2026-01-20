import ExceptionCatcher
import Foundation
import SQLite
import SwiftServerFoundation

/// Search result containing the message ROWID for fetching full data
public struct SearchMatchedMessage {
    public let rowID: Int
}

private let searchQuerySQL = """
SELECT m.ROWID, m.text, m.attributedBody
FROM message m
WHERE (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
ORDER BY m.date DESC
LIMIT ?
"""

public extension IMDatabase {
    /// Searches messages by text content, properly decoding attributedBody.
    /// Returns ROWIDs of matching messages that can be used to fetch full message data.
    /// - Parameters:
    ///   - query: The search term (case-insensitive)
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of ROWIDs for messages that match the search query
    func searchMessages(
        query: String,
        limit: Int = 20
    ) throws -> [Int] {
        let queryLower = query.lowercased()

        // Fetch more than limit to account for filtering - we'll filter in Swift after decoding
        let fetchLimit = limit * 20

        let statement = try cachedStatement(forEscapedSQL: searchQuerySQL).reset()
        try statement.bind(fetchLimit)

        var matchingRowIDs: [Int] = []

        try statement.stepUntilDone { row in
            // Stop once we have enough results
            guard matchingRowIDs.count < limit else { return }

            let rowID = try row[0].expect(Int.self)
            let plainText = try row[1].optional(String.self)
            let attributedBodyData = try row[2].optional(Data.self)

            // Try to get text from attributedBody first (more complete), fall back to text column
            var messageText: String? = nil

            if let data = attributedBodyData,
               let unarchiver = try? NSUnarchiver(forReadingWith: data),
               let decoded = try? ExceptionCatcher.catch { unarchiver.decodeObject() },
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
