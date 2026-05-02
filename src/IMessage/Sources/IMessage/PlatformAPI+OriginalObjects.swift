import Foundation
import IMDatabase
import IMessageCore
import Logging

private let platformOriginalObjectsLog = Logger(imessageLabel: "platform-api")

extension PlatformAPI {
    nonisolated static func messageOriginalPayload(
        msgRow: MappedMessageRow,
        attachmentRows: [MappedAttachmentRow],
        currentUserID: String
    ) -> [Any] {
        var serializedRow = msgRow.object
        serializedRow.removeValue(forKey: "attributedBody")
        serializedRow.removeValue(forKey: "message_summary_info")
        return [serializedRow, attachmentRows.map(\.object), currentUserID]
    }

    nonisolated static func threadOriginalPayload(
        chatRow: MappedChatRow,
        handleRows: [MappedHandleRow]
    ) -> [Any] {
        [chatRow.object, handleRows.map(\.object)]
    }

    nonisolated static func getOriginalObject(
        db: IMDatabase,
        objName: String,
        objectID: String,
        currentUserID: String
    ) throws -> String {
        switch objName {
        case "message":
            let messageGUID = objectID.components(separatedBy: "_").first ?? objectID
            guard let msgRow = try db.mappedMessageRow(guid: messageGUID) else {
                return ""
            }
            let attachmentRows = decorateAttachments(try db.mappedAttachmentRows(messageRowIDs: [msgRow.rowID]))
            return encodeOriginalPayload(messageOriginalPayload(
                msgRow: msgRow,
                attachmentRows: attachmentRows,
                currentUserID: currentUserID
            ))

        case "thread":
            let threadID = try originalThreadID(db: db, objectID)
            guard let chatRow = try db.mappedThreadRow(guid: threadID) else {
                return ""
            }
            let handleRowsByChatRowID = try db.mappedThreadParticipantRows(chatRowIDs: [chatRow.rowID])
            return encodeOriginalPayload(threadOriginalPayload(
                chatRow: chatRow,
                handleRows: handleRowsByChatRowID[chatRow.rowID] ?? []
            ))

        default:
            throw ErrorMessage("Bad PlatformAPI call: getOriginalObject objName must be 'thread' or 'message'")
        }
    }

    nonisolated private static func encodeOriginalPayload(_ payload: Any) -> String {
        do {
            return try encodeJSON(payload)
        } catch {
            platformOriginalObjectsLog.error("failed to encode original object payload: \(error)")
            return ""
        }
    }
}
