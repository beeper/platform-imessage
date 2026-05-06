import GRDB
import IMessageCore
import Logging

private let log = Logger(label: "imdb.chats")

public extension IMDatabase {
    // TODO: replace with overload that takes `GUID`
    func chat(withGUID chatGUID: String) throws -> Chat? {
        let chats = try read { db in
            try Row.fetchAll(db, sql: """
            SELECT ROWID, display_name, service_name
            FROM chat
            WHERE guid = ?
            """, arguments: [chatGUID]).map { row in
                let displayName = row.optionalString(at: 1)?.nonEmpty
                let serviceName = Chat.ServiceName(rawValue: row.requiredString(at: 2))
                return Chat(id: row.requiredInt(at: 0), guid: GUID(chatGUID), displayName: displayName, serviceName: serviceName)
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
            try Row.fetchAll(db, sql: """
            SELECT ROWID, guid, display_name, service_name
            FROM chat
            """).compactMap { row -> Chat? in
                let id = row.requiredInt(at: 0)
                guard let guid = row.optionalString(at: 1) else {
                    log.error("chat \(id) has no GUID, very spooky. dropping it on the ground")
                    return nil
                }
                let displayName = row.optionalString(at: 2)?.nonEmpty
                let serviceName = Chat.ServiceName(rawValue: row.optionalString(at: 3) ?? "NONE")
                return Chat(id: id, guid: GUID(guid), displayName: displayName, serviceName: serviceName)
            }
        }
    }

    // this doesn't include the user themselves, just everyone else in the group chat,
    // UNLESS the user went out of their way to redundantly add themselves, which is possible when initially creating the chat
    func handles(inChatWithGUID chatGUID: String) throws -> [Handle] {
        try read { db in
            try Row.fetchAll(db, sql: """
            SELECT handle.ROWID, handle.id
            FROM chat
            INNER JOIN chat_handle_join ON chat_handle_join.chat_id = chat.ROWID
            INNER JOIN handle ON handle.ROWID = chat_handle_join.handle_id
            WHERE chat.guid = ?
            """, arguments: [chatGUID]).map { row in
                Handle(rowid: row.requiredInt(at: 0), id: row.requiredString(at: 1))
            }
        }
    }
}
