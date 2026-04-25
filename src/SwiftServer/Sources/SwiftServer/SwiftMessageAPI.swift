import Foundation
import IMDatabase
import SwiftServerFoundation

private let messagePageLimit = 20

enum SwiftMessageAPI {
    static func getMessages(
        threadID publicThreadID: String,
        cursor: String?,
        direction: String?,
        currentUserID: String,
        accountID: String
    ) throws -> String {
        let db = try IMDatabase()
        let threadID = try originalThreadID(publicThreadID, db: db)
        let pageDirection = direction.flatMap(MappedMessagePageDirection.init(rawValue:))
        var msgRows = try db.mappedMessageRows(
            in: threadID,
            cursor: cursor,
            direction: pageDirection,
            limit: messagePageLimit
        )
        if pageDirection != .after {
            msgRows.reverse()
        }

        let messages = try mapAndHashMessages(
            msgRows: msgRows,
            db: db,
            threadID: threadID,
            currentUserID: currentUserID,
            accountID: accountID
        )
        return try encodeJSON([
            "items": messages,
            "hasMore": msgRows.count == messagePageLimit,
        ])
    }

    static func getMessage(
        threadID publicThreadID: String,
        messageID: String,
        currentUserID: String,
        accountID: String
    ) throws -> String {
        let db = try IMDatabase()
        let threadID = try originalThreadID(publicThreadID, db: db)
        let messageGUID = messageID.components(separatedBy: "_").first ?? messageID
        guard let msgRow = try db.mappedMessageRow(guid: messageGUID) else {
            return "null"
        }

        let messages = try mapAndHashMessages(
            msgRows: [msgRow],
            db: db,
            threadID: threadID,
            currentUserID: currentUserID,
            accountID: accountID
        )
        guard let message = messages.first(where: { ($0["id"] as? String) == messageID }) else {
            return "null"
        }
        return try encodeJSON(message)
    }
}

private extension SwiftMessageAPI {
    static func originalThreadID(_ threadID: String, db: IMDatabase) throws -> String {
        guard threadID.hasPrefix("imsg") else {
            return threadID
        }
        do {
            return try Hasher.thread.recoverOriginal(fromToken: threadID)
        } catch {
            for guid in try db.allThreadGUIDs() {
                _ = Hasher.thread.tokenizeRemembering(pii: guid)
            }
            return try Hasher.thread.recoverOriginal(fromToken: threadID)
        }
    }

    static func mapAndHashMessages(
        msgRows: [JSONObject],
        db: IMDatabase,
        threadID: String,
        currentUserID: String,
        accountID: String
    ) throws -> [JSONObject] {
        guard !msgRows.isEmpty else {
            return []
        }

        let msgRowIDs = msgRows.compactMap { $0.int("ROWID") }
        let msgGUIDs = msgRows.compactMap { $0.string("guid") }
        let attachmentRows = decorateAttachments(try db.mappedAttachmentRows(messageRowIDs: msgRowIDs))
        let reactionRows = try db.mappedReactionRows(messageGUIDs: msgGUIDs, chatGUID: threadID)
        let attachmentRowsByMessageID = Dictionary(grouping: attachmentRows, by: { $0.int("msgRowID") ?? -1 })
        let reactionRowsByMessageGUID = Dictionary(grouping: reactionRows, by: { reactionMessageGUID($0.string("associated_message_guid") ?? "") })

        return try msgRows.flatMap { msgRow -> [JSONObject] in
            let mapper = try Mapper(input: [
                "msgRow": msgRow,
                "attachmentRows": attachmentRowsByMessageID[msgRow.int("ROWID") ?? -1] ?? [],
                "reactionRows": reactionRowsByMessageGUID[msgRow.string("guid") ?? ""] ?? [],
                "currentUserID": currentUserID,
                "accountID": accountID,
            ])
            let mapped = try mapper.mapMessage().filter { shouldKeepForAPI($0) }
            return attachOriginalIfNeeded(
                mapped,
                msgRow: msgRow,
                attachmentRows: attachmentRowsByMessageID[msgRow.int("ROWID") ?? -1] ?? [],
                currentUserID: currentUserID
            ).map(hashMessage)
        }
    }

    static func shouldKeepForAPI(_ message: JSONObject) -> Bool {
        !message.isEmpty
    }

    static func attachOriginalIfNeeded(
        _ messages: [JSONObject],
        msgRow: JSONObject,
        attachmentRows: [JSONObject],
        currentUserID: String
    ) -> [JSONObject] {
        guard ProcessInfo.processInfo.environment["IMESSAGE_STRIP_INTERNAL_FIELDS"] != "1" else {
            return messages
        }

        var serializedRow = msgRow
        serializedRow.removeValue(forKey: "attributedBody")
        serializedRow.removeValue(forKey: "message_summary_info")
        let original = (try? encodeJSON([serializedRow, attachmentRows, currentUserID])) ?? ""
        return messages.map { message in
            var message = message
            message["_original"] = original
            return message
        }
    }

    static func hashMessage(_ message: JSONObject) -> JSONObject {
        var message = message
        if let threadID = message.string("threadID") {
            message["threadID"] = Hasher.thread.tokenizeRemembering(pii: threadID)
        }
        if let senderID = message.string("senderID") {
            message["senderID"] = Hasher.participant.tokenizeRemembering(pii: senderID)
        }
        if let reactions = message["reactions"] as? [JSONObject] {
            message["reactions"] = reactions.map { reaction in
                var reaction = reaction
                if let id = reaction.string("id") {
                    reaction["id"] = Hasher.participant.tokenizeRemembering(pii: id)
                }
                if let participantID = reaction.string("participantID") {
                    reaction["participantID"] = Hasher.participant.tokenizeRemembering(pii: participantID)
                }
                return reaction
            }
        }
        return message
    }

    static func decorateAttachments(_ attachmentRows: [JSONObject]) -> [JSONObject] {
        attachmentRows.map { attachmentRow in
            var attachmentRow = attachmentRow
            let rawFilePath = attachmentRow.string("filename")
            let filePath = rawFilePath.map(replaceTilde)
            let transferName = attachmentRow.string("transfer_name")
            let base = filePath.map { ($0 as NSString).lastPathComponent } ?? transferName ?? ""
            let ext = filePath.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
            attachmentRow["filePath"] = filePath ?? NSNull()
            attachmentRow["fileName"] = transferName?.isEmpty == false ? transferName! : base
            attachmentRow["ext"] = ext

            if let filePath,
               imageExtensions.contains(ext) || ext == "pluginpayloadattachment",
               let size = ImageMetadataReader.read(from: filePath) {
                attachmentRow["size"] = [
                    "width": size.width,
                    "height": size.height,
                ]
            }
            return attachmentRow
        }
    }

    static func reactionMessageGUID(_ associatedMessageGUID: String) -> String {
        guard let range = associatedMessageGUID.range(
            of: #"^(?:p:[-\d]+/|bp:)"#,
            options: .regularExpression
        ) else {
            return associatedMessageGUID
        }
        return String(associatedMessageGUID[range.upperBound...])
    }

    static func encodeJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try String(data: data, encoding: .utf8).orThrow(ErrorMessage("Swift message API output wasn't utf8"))
    }

    static func replaceTilde(_ string: String) -> String {
        guard string.first == "~" else {
            return string
        }
        return NSHomeDirectory() + String(string.dropFirst())
    }
}
