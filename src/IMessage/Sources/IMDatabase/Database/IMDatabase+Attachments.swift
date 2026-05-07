import Collections
import GRDB
import Logging
import IMessageCore

private let log = Logger(imessageLabel: "imdb.db")

let attachmentQuerySharedPrologue = """
SELECT m.ROWID, a.ROWID, a.guid, a.filename, a.transfer_name, a.is_sticker, a.transfer_state, a.uti
FROM message m
LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
"""

extension IMDatabase {
    func hydrateAttachments(for message: inout Message) throws {
        let attachments = try read { db in
            try Row.fetchAll(db, sql: """
            \(attachmentQuerySharedPrologue)
            WHERE m.guid = ?
            """, arguments: [message.guid]).compactMap { row in
                try Attachment(row: row)
            }
        }
        message.attachments = attachments
        #if DEBUG
        log.debug("[attachment hydration] \(message.guid) attachments hydrated => \(attachments.count)")
        #endif
    }

    func hydrateAttachments(for messages: inout OrderedDictionary<Message.ID, Message>) throws {
        let messageRowIDs = messages.keys.map(String.init)

        try read { db in
            let rows = try Row.fetchAll(db, sql: """
            \(attachmentQuerySharedPrologue)
            WHERE m.ROWID IN (\(messageRowIDs.joined(separator: ",")))
            """)
            for row in rows {
                let messageRowID = row.requiredInt(at: 0)

                guard messages[messageRowID] != nil else {
                    assertionFailure()
                    continue
                }

                if messages[messageRowID]!.attachments == nil {
                    messages[messageRowID]!.attachments = []
                }

                guard let attachment = try Attachment(row: row) else {
                    continue
                }

                messages[messageRowID]!.attachments!.append(attachment)
            }
        }
    }
}

extension Attachment {
    init?(row: Row) throws {
        // (skipping `m.ROWID`)
        guard let attachmentRowID = row.optionalInt(at: 1) else {
            return nil
        }
        let attachmentGUID = GUID<Attachment>(row.requiredString(at: 2))
        let fileName = row.optionalString(at: 3)
        let transferName = row.optionalString(at: 4)
        let isSticker = row.looseBool(at: 5)
        let transferState = Attachment.IMFileTransferState(rawValue: row.requiredInt(at: 6))
        let uti = row.optionalString(at: 7)

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
