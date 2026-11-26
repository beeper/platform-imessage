import Foundation
@testable import IMDatabase
@testable import SQLite

/// A small `chat.db` with one chat, for tests that insert the few rows they need.
final class ChatDatabaseFixture {
    static let defaultChatGUID = "any;-;+15555550100"

    let chatGUID: String
    let directory: URL
    let databasePath: String
    let database: Database
    let imDatabase: IMDatabase
    /// `message.date_edited` arrived in macOS 13.
    private let hasDateEdited: Bool

    init(
        chatGUID: String = ChatDatabaseFixture.defaultChatGUID,
        schema: String = ChatDatabaseSchema.tahoe
    ) throws {
        self.chatGUID = chatGUID
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        databasePath = directory.appendingPathComponent("chat.db").path
        database = try Database(connecting: databasePath, flags: [.readWrite, .createIfNecessary])
        try ChatDatabaseSchema.create(schema, in: database)
        hasDateEdited = try database.tableColumns("message").contains("date_edited")
        try database.execute(sqlWithoutEscaping: "INSERT INTO chat (ROWID, guid) VALUES (1, ?)", chatGUID)

        imDatabase = try IMDatabase(messagesDataBaseURL: directory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func insertMessage(
        rowID: Int,
        guid: String? = nil,
        text: String = "",
        attributedBody: Data? = nil,
        date: Int? = nil,
        dateRead: Int64 = 0,
        dateEdited: Int64 = 0,
        service: String = "iMessage"
    ) throws {
        try database.execute(
            sqlWithoutEscaping: """
            INSERT INTO message (ROWID, guid, text, attributedBody, date, date_read, service)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            rowID,
            guid ?? "message-\(rowID)",
            text,
            attributedBody,
            date ?? rowID,
            dateRead,
            service
        )
        if hasDateEdited {
            try database.execute(sqlWithoutEscaping: "UPDATE message SET date_edited = ? WHERE ROWID = ?", dateEdited, rowID)
        }
    }

    /// Inserts non-matching filler messages so search has to scan past them.
    func insertFillerMessages(rowIDs: ClosedRange<Int>) throws {
        for rowID in rowIDs {
            try insertMessage(rowID: rowID, text: "recent filler \(rowID)")
        }
    }

    /// Builds an `attributedBody` blob in the same NSArchiver/typedstream format
    /// `chat.db` stores and `AttributedBodyDecoder` reads.
    static func attributedBody(_ string: String) -> Data {
        NSArchiver.archivedData(withRootObject: NSAttributedString(string: string))
    }

    func insertChatJoin(
        messageRowID: Int,
        chatRowID: Int = 1,
        messageDate: Int? = nil
    ) throws {
        try Self.insertChatJoin(
            messageRowID: messageRowID,
            chatRowID: chatRowID,
            messageDate: messageDate ?? messageRowID,
            into: database
        )
    }

    func insertChatJoin(
        messageRowID: Int,
        after delay: TimeInterval,
        chatRowID: Int = 1,
        messageDate: Int? = nil
    ) {
        let databasePath = databasePath
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            guard let database = try? Database(connecting: databasePath, flags: .readWrite) else {
                return
            }
            try? Self.insertChatJoin(
                messageRowID: messageRowID,
                chatRowID: chatRowID,
                messageDate: messageDate ?? messageRowID,
                into: database
            )
        }
    }

    func updateMessagePayloadData(rowID: Int, payloadData: Data) throws {
        try database.execute(sqlWithoutEscaping: "UPDATE message SET payload_data = ? WHERE ROWID = ?", payloadData, rowID)
    }

    func insertAttachment(
        rowID: Int,
        messageRowID: Int,
        guid: String? = nil,
        filename: String,
        transferName: String? = nil,
        totalBytes: Int = 0,
        transferState: Int
    ) throws {
        try database.execute(
            sqlWithoutEscaping: """
            INSERT INTO attachment (ROWID, guid, original_guid, filename, transfer_name, total_bytes, transfer_state)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            rowID,
            guid ?? "attachment-\(rowID)",
            "original-attachment-\(rowID)",
            filename,
            transferName ?? (filename as NSString).lastPathComponent,
            totalBytes,
            transferState
        )
        try database.execute(
            sqlWithoutEscaping: "INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)",
            messageRowID,
            rowID
        )
    }

    func updateAttachmentTransferState(rowID: Int, transferState: Int) throws {
        try database.execute(
            sqlWithoutEscaping: "UPDATE attachment SET transfer_state = ? WHERE ROWID = ?",
            transferState,
            rowID
        )
    }

    private static func insertChatJoin(
        messageRowID: Int,
        chatRowID: Int,
        messageDate: Int,
        into database: Database
    ) throws {
        try database.execute(
            sqlWithoutEscaping: """
            INSERT INTO chat_message_join (chat_id, message_id, message_date)
            VALUES (?, ?, ?)
            """,
            chatRowID,
            messageRowID,
            messageDate
        )
    }
}
