import Collections
import Logging
import SQLite
import SwiftServerFoundation

private let log = Logger(swiftServerLabel: "imdb.db")

let attachmentQuerySharedPrologue = """
SELECT m.ROWID, a.ROWID, a.guid, a.filename, a.transfer_name, a.is_sticker, a.transfer_state, a.uti
FROM message m
LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
"""

extension IMDatabase {
    func hydrateAttachments(for message: inout Message) throws {
        let statement = try cachedStatement(forEscapedSQL: """
        \(attachmentQuerySharedPrologue)
        WHERE m.guid = ?
        """).reset()
        try statement.bind(message.guid)

        let attachments = try statement.compactMapRowsUntilDone { row in
            try Attachment(row: row)
        }
        message.attachments = attachments
#if DEBUG
        log.debug("[attachment hydration] \(message.guid) attachments hydrated => \(attachments.count)")
#endif
    }

    func hydrateAttachments(for messages: inout OrderedDictionary<Message.ID, Message>) throws {
        let messageRowIDs = messages.keys.map(String.init)

        let statement = try Statement.prepare(escapedSQL: """
        \(attachmentQuerySharedPrologue)
        WHERE m.ROWID IN (\(messageRowIDs.joined(separator: ",")))
        """, for: database)

        try statement.stepUntilDone { row in
            let messageRowID = try row[0].expect(Int.self)

            guard messages[messageRowID] != nil else {
                assertionFailure()
                return
            }

            if messages[messageRowID]!.attachments == nil {
                messages[messageRowID]!.attachments = []
            }

            guard let attachment = try Attachment(row: row) else {
                return
            }

            messages[messageRowID]!.attachments!.append(attachment)
        }
    }
}

extension Attachment {
    init?(row: borrowing Row) throws {
        // (skipping `m.ROWID`)
        guard let attachmentRowID = try row[1].optionalConverting(Int.self) else {
            return nil
        }
        let attachmentGUID = try GUID<Attachment>(row[2].expect(String.self))
        let fileName = try row[3].optionalConverting(String.self)
        let transferName = try row[4].optionalConverting(String.self)
        let isSticker = try row[5].looseBool()
        let transferState = try Attachment.TransferState(rawValue: row[6].expectConverting(Int.self))
        let uti = try row[7].optionalConverting(String.self)

        self = Attachment(
            id: attachmentRowID,
            guid: attachmentGUID,
            fileName: fileName,
            transferName: transferName,
            isSticker: isSticker,
            transferState: transferState,
            uti: uti,
        )
    }
}
