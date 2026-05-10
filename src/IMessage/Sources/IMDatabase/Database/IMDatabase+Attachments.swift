import Collections
import Logging
import IMessageCore
import SQLiteData

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
            try fetchAllSQL(AttachmentQueryRow.self, db: db, sql: """
            \(attachmentQuerySharedPrologue)
            WHERE m.guid = ?
            """, arguments: [message.guid]).compactMap(Attachment.init(row:))
        }
        message.attachments = attachments
        #if DEBUG
        log.debug("[attachment hydration] \(message.guid) attachments hydrated => \(attachments.count)")
        #endif
    }

    func hydrateAttachments(for messages: inout OrderedDictionary<Message.ID, Message>) throws {
        let messageRowIDs = messages.keys.map(String.init)

        try read { db in
            let rows = try fetchAllSQL(AttachmentQueryRow.self, db: db, sql: """
            \(attachmentQuerySharedPrologue)
            WHERE m.ROWID IN (\(messageRowIDs.joined(separator: ",")))
            """)
            for row in rows {
                let messageRowID = row.messageRowID

                guard messages[messageRowID] != nil else {
                    assertionFailure()
                    continue
                }

                if messages[messageRowID]!.attachments == nil {
                    messages[messageRowID]!.attachments = []
                }

                guard let attachment = Attachment(row: row) else {
                    continue
                }

                messages[messageRowID]!.attachments!.append(attachment)
            }
        }
    }
}

extension Attachment {
    init?(row: AttachmentQueryRow) {
        guard let attachmentRowID = row.attachmentRowID else {
            return nil
        }

        self = Attachment(
            id: attachmentRowID,
            guid: GUID<Attachment>(row.guid),
            fileName: row.fileName,
            transferName: row.transferName,
            isSticker: row.isSticker,
            transferState: row.transferState,
            uti: row.uti,
            )
    }
}

@Selection
struct AttachmentQueryRow {
    @Column("ROWID")
    let messageRowID: Int
    @Column("ROWID")
    let attachmentRowID: Int?
    let guid: String
    @Column("filename")
    let fileName: String?
    @Column("transfer_name")
    let transferName: String?
    @Column("is_sticker", as: LooseBoolRepresentation.self)
    let isSticker: Bool
    @Column("transfer_state")
    let transferState: Attachment.IMFileTransferState
    let uti: String?
}

extension Attachment.IMFileTransferState: QueryBindable {
    public typealias QueryValue = Int

    public var queryBinding: QueryBinding {
        rawValue.queryBinding
    }
}
