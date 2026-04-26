import Foundation
import IMDatabase
import NodeAPI
import SwiftServerFoundation

private let messagePageLimit = 20
// These APIs return JSON strings; this is the JSON null literal.
private let jsonNull = "null"
let stripInternalFields = ProcessInfo.processInfo.environment["IMESSAGE_STRIP_INTERNAL_FIELDS"] == "1"

@NodeActor @NodeClass final class PlatformAPI {
    static let name = "PlatformAPI"

    private let currentUserID: String
    private let accountID: String

    @NodeConstructor init(currentUserID: String, accountID: String) {
        self.currentUserID = currentUserID
        self.accountID = accountID
    }

    private static func offNodeActor<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try action()
        }.value
    }

    @NodeMethod func getMessages(threadID: String, cursor: String?, direction: String?, limit: Int?) async throws -> String {
        let currentUserID = currentUserID
        let accountID = accountID
        return try await Self.offNodeActor {
            try Self.getMessages(
                threadID: threadID,
                cursor: cursor,
                direction: direction,
                currentUserID: currentUserID,
                accountID: accountID,
                limit: limit
            )
        }
    }

    @NodeMethod func getMessage(threadID: String, messageID: String) async throws -> String {
        let currentUserID = currentUserID
        let accountID = accountID
        return try await Self.offNodeActor {
            try Self.getMessage(
                threadID: threadID,
                messageID: messageID,
                currentUserID: currentUserID,
                accountID: accountID
            )
        }
    }

    @NodeMethod func getThreads(folderName: String, cursor: String?, direction: String?) async throws -> String {
        let currentUserID = currentUserID
        let accountID = accountID
        return try await Self.offNodeActor {
            try Self.getThreads(
                folderName: folderName,
                cursor: cursor,
                direction: direction,
                currentUserID: currentUserID,
                accountID: accountID
            )
        }
    }

    @NodeMethod func getThread(threadID: String) async throws -> String {
        let currentUserID = currentUserID
        let accountID = accountID
        return try await Self.offNodeActor {
            try Self.getThread(
                threadID: threadID,
                currentUserID: currentUserID,
                accountID: accountID
            )
        }
    }

    nonisolated static func getThreads(
        folderName: String,
        cursor: String?,
        direction: String?,
        currentUserID: String,
        accountID: String
    ) throws -> String {
        guard folderName == "normal" else {
            return try encodeJSON([
                "items": [],
                "hasMore": false,
                "oldestCursor": "0",
            ])
        }

        let db = try IMDatabase()
        let pageDirection = direction.flatMap(MappedThreadPageDirection.init(rawValue:))
        let chatRows = try db.mappedThreadRows(cursor: cursor, direction: pageDirection)
        let latestMessageRowsByChatGUID = try ThreadMapper.latestMessageRowsByChatGUID(chatRows: chatRows, db: db)
        let context = try ThreadMapper.context(
            chatRows: chatRows,
            latestMessageRowsByChatGUID: latestMessageRowsByChatGUID,
            db: db,
            currentUserID: currentUserID,
            accountID: accountID
        )
        let threads = try chatRows.map { try ThreadMapper.mapAndHashThread($0, context: context) }
        return try encodeJSON(compactDictionary([
            "items": threads,
            "hasMore": chatRows.count == mappedThreadsLimit,
            "oldestCursor": chatRows.last?.string("msgDateString"),
            "_pollingCursor": cursor == nil ? ThreadMapper.pollingCursor(from: latestMessageRowsByChatGUID.values.map { $0 }) : nil,
        ]))
    }

    nonisolated static func getThread(
        threadID publicThreadID: String,
        currentUserID: String,
        accountID: String
    ) throws -> String {
        let db = try IMDatabase()
        let threadID = try originalThreadID(publicThreadID, db: db)
        guard let chatRow = try db.mappedThreadRow(guid: threadID) else {
            return jsonNull
        }
        let latestMessageRowsByChatGUID = try ThreadMapper.latestMessageRowsByChatGUID(chatRows: [chatRow], db: db)
        let context = try ThreadMapper.context(
            chatRows: [chatRow],
            latestMessageRowsByChatGUID: latestMessageRowsByChatGUID,
            db: db,
            currentUserID: currentUserID,
            accountID: accountID
        )
        return try encodeJSON(ThreadMapper.mapAndHashThread(chatRow, context: context))
    }

    nonisolated static func getMessages(
        threadID publicThreadID: String,
        cursor: String?,
        direction: String?,
        currentUserID: String,
        accountID: String,
        limit: Int? = nil
    ) throws -> String {
        let db = try IMDatabase()
        let threadID = try originalThreadID(publicThreadID, db: db)
        let pageDirection = direction.flatMap(MappedMessagePageDirection.init(rawValue:))
        let effectiveLimit = limit ?? messagePageLimit
        var msgRows = try db.mappedMessageRows(
            in: threadID,
            cursor: cursor,
            direction: pageDirection,
            limit: effectiveLimit
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
            "hasMore": msgRows.count == effectiveLimit,
        ])
    }

    nonisolated static func getMessage(
        threadID publicThreadID: String,
        messageID: String,
        currentUserID: String,
        accountID: String
    ) throws -> String {
        let db = try IMDatabase()
        let threadID = try originalThreadID(publicThreadID, db: db)
        let messageGUID = messageID.components(separatedBy: "_").first ?? messageID
        guard let msgRow = try db.mappedMessageRow(guid: messageGUID) else {
            return jsonNull
        }

        let messages = try mapAndHashMessages(
            msgRows: [msgRow],
            db: db,
            threadID: threadID,
            currentUserID: currentUserID,
            accountID: accountID
        )
        guard let message = messages.first(where: { ($0["id"] as? String) == messageID }) else {
            return jsonNull
        }
        return try encodeJSON(message)
    }
}

extension PlatformAPI {
    nonisolated static func originalThreadID(_ threadID: String, db: IMDatabase) throws -> String {
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

    nonisolated static func mapAndHashMessages(
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
            let attachments = attachmentRowsByMessageID[msgRow.int("ROWID") ?? -1] ?? []
            let mapper = try Mapper(input: [
                "msgRow": msgRow,
                "attachmentRows": attachments,
                "reactionRows": reactionRowsByMessageGUID[msgRow.string("guid") ?? ""] ?? [],
                "currentUserID": currentUserID,
                "accountID": accountID,
            ])
            let mapped = try mapper.mapMessage().filter { shouldKeepForAPI($0) }
            return attachOriginalIfNeeded(
                mapped,
                msgRow: msgRow,
                attachmentRows: attachments,
                currentUserID: currentUserID
            ).map(hashMessage)
        }
    }

    nonisolated static func shouldKeepForAPI(_ message: JSONObject) -> Bool {
        !message.isEmpty
    }

    nonisolated static func attachOriginalIfNeeded(
        _ messages: [JSONObject],
        msgRow: JSONObject,
        attachmentRows: [JSONObject],
        currentUserID: String
    ) -> [JSONObject] {
        guard !stripInternalFields else {
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

    nonisolated static func hashMessage(_ message: JSONObject) -> JSONObject {
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

    nonisolated static func decorateAttachments(_ attachmentRows: [JSONObject]) -> [JSONObject] {
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

    nonisolated static let reactionPrefixRegex = try! NSRegularExpression(pattern: #"^(?:p:[-\d]+/|bp:)"#)

    nonisolated static func reactionMessageGUID(_ associatedMessageGUID: String) -> String {
        let range = NSRange(associatedMessageGUID.startIndex ..< associatedMessageGUID.endIndex, in: associatedMessageGUID)
        guard let match = reactionPrefixRegex.firstMatch(in: associatedMessageGUID, range: range),
              let upper = Range(match.range, in: associatedMessageGUID)?.upperBound else {
            return associatedMessageGUID
        }
        return String(associatedMessageGUID[upper...])
    }

    nonisolated static func encodeJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try String(data: data, encoding: .utf8).orThrow(ErrorMessage("Swift message API output wasn't utf8"))
    }

    nonisolated static func replaceTilde(_ string: String) -> String {
        guard string.first == "~" else {
            return string
        }
        return NSHomeDirectory() + String(string.dropFirst())
    }
}
