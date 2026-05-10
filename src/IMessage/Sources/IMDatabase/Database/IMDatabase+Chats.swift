import IMessageCore
import Logging
import SQLiteData

private let log = Logger(label: "imdb.chats")

public extension IMDatabase {
    // TODO: replace with overload that takes `GUID`
    func chat(withGUID chatGUID: String) throws -> Chat? {
        let chats = try read { db in
            try fetchAllSQL(ChatLookupRow.self, db: db, sql: """
            SELECT ROWID, display_name, service_name
            FROM chat
            WHERE guid = ?
            """, arguments: [chatGUID]).map { row in
                Chat(id: row.rowID, guid: GUID(chatGUID), displayName: row.displayName?.nonEmpty, serviceName: row.serviceName)
            }
        }

        if chats.count > 1 {
            log.warning("database anomaly: more than one chat returned by guid query")
        }
        return chats.first
    }

    func chat(withGUID guid: GUID<Chat>) throws -> Chat? {
        try chat(withGUID: guid.guts)
    }

    func chats() throws -> [Chat] {
        try read { db in
            try fetchAllSQL(ChatListRow.self, db: db, sql: """
            SELECT ROWID, guid, display_name, service_name
            FROM chat
            """).compactMap { row -> Chat? in
                let id = row.rowID
                guard let guid = row.guid else {
                    log.error("chat \(id) has no GUID, very spooky. dropping it on the ground")
                    return nil
                }
                return Chat(id: id, guid: GUID(guid), displayName: row.displayName?.nonEmpty, serviceName: row.serviceName)
            }
        }
    }

    // this doesn't include the user themselves, just everyone else in the group chat,
    // UNLESS the user went out of their way to redundantly add themselves, which is possible when initially creating the chat
    func handles(inChatWithGUID chatGUID: String) throws -> [Handle] {
        try read { db in
            try fetchAllSQL(HandleLookupRow.self, db: db, sql: """
            SELECT handle.ROWID, handle.id
            FROM chat
            INNER JOIN chat_handle_join ON chat_handle_join.chat_id = chat.ROWID
            INNER JOIN handle ON handle.ROWID = chat_handle_join.handle_id
            WHERE chat.guid = ?
            """, arguments: [chatGUID]).map { row in
                Handle(rowid: row.rowID, id: row.id)
            }
        }
    }
}

private struct ChatLookupRow: QueryRepresentable {
    typealias QueryOutput = Self

    let rowID: Int
    let displayName: String?
    let serviceName: Chat.ServiceName

    init(decoder: inout some QueryDecoder) throws {
        rowID = try decoder.requiredInt("ROWID", row: Self.self)
        displayName = try decoder.optionalString()
        serviceName = Chat.ServiceName(rawValue: try decoder.requiredString("service_name", row: Self.self))
    }
}

private struct ChatListRow: QueryRepresentable {
    typealias QueryOutput = Self

    let rowID: Int
    let guid: String?
    let displayName: String?
    let serviceName: Chat.ServiceName

    init(decoder: inout some QueryDecoder) throws {
        rowID = try decoder.requiredInt("ROWID", row: Self.self)
        guid = try decoder.optionalString()
        displayName = try decoder.optionalString()
        serviceName = Chat.ServiceName(rawValue: try decoder.optionalString() ?? "NONE")
    }
}

private struct HandleLookupRow: QueryRepresentable {
    typealias QueryOutput = Self

    let rowID: Int
    let id: String

    init(decoder: inout some QueryDecoder) throws {
        rowID = try decoder.requiredInt("ROWID", row: Self.self)
        id = try decoder.requiredString("id", row: Self.self)
    }
}
