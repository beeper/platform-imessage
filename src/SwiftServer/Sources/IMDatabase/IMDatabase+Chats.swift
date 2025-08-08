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
            let displayName = try row[1].optional(String.self)?.nonEmpty
            return try Chat(id: row[0].expect(Int.self), guid: chatGUID, displayName: displayName)
        }

        if chats.count > 1 {
            log.warning("database anomaly: more than one chat returned by guid query")
        }
        return chats.first
    }

    func chats() throws -> [Chat] {
        let statement = try cachedStatement(&allChatsStatement, creatingWithoutEscapingSQL: """
        SELECT ROWID, guid, display_name
        FROM chat
        """)

        try statement.reset()

        return try statement.mapRowsUntilDone { row -> Chat? in
            let id = try row[0].expect(Int.self)
            guard let guid = try row[1].optional(String.self) else {
                log.error("chat \(id) has no GUID, very spooky. dropping it on the ground")
                return nil
            }
            return try Chat(id: id, guid: guid, displayName: row[2].optional(String.self))
        }.compactMap(\.self)
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
            try Handle(rowid: row[0].expect(Int.self), id: row[1].expect(String.self))
        }
    }
}

private extension String {
    var nonEmpty: String? {
        guard !isEmpty else { return nil }
        return self
    }
}
