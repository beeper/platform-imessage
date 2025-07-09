import Logging

private let log = Logger(label: "imdb.chats")

public extension IMDatabase {
    func chat(withGUID chatGUID: String) throws -> Chat? {
        let statement = try cachedStatement(&chatWithGUIDStatement, creatingWithoutEscapingSQL: """
        SELECT ROWID, display_name
        FROM chat
        WHERE guid = ?
        """)

        try statement.reset()
        try statement.bind(chatGUID)

        let chats = try statement.mapRowsUntilDone { row in
            let displayName = row[1].as(String.self)?.nonEmpty
            return Chat(id: row[0].as(Int.self), guid: chatGUID, displayName: displayName)
        }

        if chats.count > 1 {
            log.warning("database anomaly: more than one chat returned by guid query")
        }
        return chats.first
    }

    // this doesn't include the user themselves, just everyone else in the group chat,
    // UNLESS the user went out of their way to redundantly add themselves, which is possible when initially creating the chat
    func handles(inChatWithGUID chatGUID: String) throws -> [Handle] {
        let statement = try cachedStatement(&handlesInChatWithGUIDStatement, creatingWithoutEscapingSQL: """
        SELECT handle.ROWID, handle.id
        FROM chat
        INNER JOIN chat_handle_join ON chat_handle_join.chat_id = chat.ROWID
        INNER JOIN handle ON handle.ROWID = chat_handle_join.handle_id
        WHERE chat.guid = ?
        """)

        try statement.reset()
        try statement.bind(chatGUID)

        return try statement.mapRowsUntilDone { row in
            return Handle(rowid: row[0].as(Int.self), id: row[1].as(String.self)!)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        guard !isEmpty else { return nil }
        return self
    }
}
