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

@Selection
private struct ChatLookupRow {
    @Column("ROWID")
    let rowID: Int
    @Column("display_name")
    let displayName: String?
    @Column("service_name", as: ChatServiceNameRepresentation.self)
    let serviceName: Chat.ServiceName
}

@Selection
private struct ChatListRow {
    @Column("ROWID")
    let rowID: Int
    let guid: String?
    @Column("display_name")
    let displayName: String?
    @Column("service_name", as: ChatServiceNameRepresentation.self)
    let serviceName: Chat.ServiceName
}

@Selection
private struct HandleLookupRow {
    @Column("ROWID")
    let rowID: Int
    let id: String
}

private struct ChatServiceNameRepresentation: QueryBindable {
    typealias QueryValue = String

    var queryOutput: Chat.ServiceName

    var queryBinding: QueryBinding {
        queryOutput.rawValue.queryBinding
    }

    init(queryOutput: Chat.ServiceName) {
        self.queryOutput = queryOutput
    }

    init(decoder: inout some QueryDecoder) throws {
        queryOutput = Chat.ServiceName(rawValue: try String?(decoder: &decoder) ?? "NONE")
    }
}
