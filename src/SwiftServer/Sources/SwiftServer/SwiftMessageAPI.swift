import Foundation
import IMDatabase
import NodeAPI
import SwiftServerFoundation

private let messagePageLimit = 20
// These APIs return JSON strings; this is the JSON null literal.
private let jsonNull = "null"
let stripInternalFields = ProcessInfo.processInfo.environment["IMESSAGE_STRIP_INTERNAL_FIELDS"] == "1"

private final class PlatformAPIDatabase: @unchecked Sendable {
    private let database = Protected<IMDatabase?>()

    func withDatabase<T>(_ action: (IMDatabase) throws -> T) throws -> T {
        try database.withLock { cachedDatabase in
            if let cachedDatabase {
                return try action(cachedDatabase)
            }

            let newDatabase = try IMDatabase()
            cachedDatabase = newDatabase
            return try action(newDatabase)
        }
    }
}

@NodeActor @NodeClass final class PlatformAPI {
    static let name = "PlatformAPI"

    private let currentUserID: String
    private let accountID: String
    private let database = PlatformAPIDatabase()

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
        let database = database
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                try Self.getMessages(
                    db: db,
                    threadID: threadID,
                    cursor: cursor,
                    direction: direction,
                    currentUserID: currentUserID,
                    accountID: accountID,
                    limit: limit
                )
            }
        }
    }

    @NodeMethod func getMessage(threadID: String, messageID: String) async throws -> String {
        let currentUserID = currentUserID
        let accountID = accountID
        let database = database
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                try Self.getMessage(
                    db: db,
                    threadID: threadID,
                    messageID: messageID,
                    currentUserID: currentUserID,
                    accountID: accountID
                )
            }
        }
    }

    @NodeMethod func getThreads(folderName: String, cursor: String?, direction: String?) async throws -> String {
        let currentUserID = currentUserID
        let accountID = accountID
        let database = database
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                try Self.getThreads(
                    db: db,
                    folderName: folderName,
                    cursor: cursor,
                    direction: direction,
                    currentUserID: currentUserID,
                    accountID: accountID
                )
            }
        }
    }

    @NodeMethod func getThread(threadID: String) async throws -> String {
        let currentUserID = currentUserID
        let accountID = accountID
        let database = database
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                try Self.getThread(
                    db: db,
                    threadID: threadID,
                    currentUserID: currentUserID,
                    accountID: accountID
                )
            }
        }
    }

    @NodeMethod func searchMessages(query: String, threadID: String?, mediaOnly: Bool?, sender: String?, limit: Int?) async throws -> String {
        let currentUserID = currentUserID
        let accountID = accountID
        let database = database
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                try Self.searchMessages(
                    db: db,
                    query: query,
                    threadID: threadID,
                    mediaOnly: mediaOnly ?? false,
                    sender: sender,
                    currentUserID: currentUserID,
                    accountID: accountID,
                    limit: limit
                )
            }
        }
    }

    nonisolated static func getThreads(
        db: IMDatabase,
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

        let pageDirection = direction.flatMap(MappedThreadPageDirection.init(rawValue:))
        let chatRows = try db.mappedThreadRows(cursor: cursor, direction: pageDirection)
        let chatRowIDs = chatRows.compactMap { $0.int("ROWID") }
        let latestMessageRowsByChatGUID = try latestThreadMessageRowsByChatGUID(db: db, chatRows: chatRows)
        let context = ThreadMapper.context(
            handleRowsByChatRowID: try db.mappedThreadParticipantRows(chatRowIDs: chatRowIDs),
            latestMessagesByChatGUID: try latestThreadMessagesByChatGUID(
                db: db,
                latestMessageRowsByChatGUID,
                currentUserID: currentUserID,
                accountID: accountID
            ),
            unreadCounts: try db.mappedUnreadCounts(chatRowIDs: chatRowIDs),
            dndState: permanentDNDThreadIDs(),
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
        db: IMDatabase,
        threadID publicThreadID: String,
        currentUserID: String,
        accountID: String
    ) throws -> String {
        let threadID = try originalThreadID(db: db, publicThreadID)
        guard let chatRow = try db.mappedThreadRow(guid: threadID) else {
            return jsonNull
        }
        let chatRowIDs = [chatRow].compactMap { $0.int("ROWID") }
        let latestMessageRowsByChatGUID = try latestThreadMessageRowsByChatGUID(db: db, chatRows: [chatRow])
        let context = ThreadMapper.context(
            handleRowsByChatRowID: try db.mappedThreadParticipantRows(chatRowIDs: chatRowIDs),
            latestMessagesByChatGUID: try latestThreadMessagesByChatGUID(
                db: db,
                latestMessageRowsByChatGUID,
                currentUserID: currentUserID,
                accountID: accountID
            ),
            unreadCounts: try db.mappedUnreadCounts(chatRowIDs: chatRowIDs),
            dndState: permanentDNDThreadIDs(),
            currentUserID: currentUserID,
            accountID: accountID
        )
        return try encodeJSON(ThreadMapper.mapAndHashThread(chatRow, context: context))
    }

    nonisolated static func getMessages(
        db: IMDatabase,
        threadID publicThreadID: String,
        cursor: String?,
        direction: String?,
        currentUserID: String,
        accountID: String,
        limit: Int? = nil
    ) throws -> String {
        let threadID = try originalThreadID(db: db, publicThreadID)
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

        let payloadRows = try messagePayloadRows(db: db, msgRows: msgRows, threadID: threadID)
        let messages = try mapAndHashMessages(
            msgRows: msgRows,
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
        return try encodeJSON([
            "items": messages,
            "hasMore": msgRows.count == effectiveLimit,
        ])
    }

    nonisolated static func getMessage(
        db: IMDatabase,
        threadID publicThreadID: String,
        messageID: String,
        currentUserID: String,
        accountID: String
    ) throws -> String {
        let threadID = try originalThreadID(db: db, publicThreadID)
        let messageGUID = messageID.components(separatedBy: "_").first ?? messageID
        guard let msgRow = try db.mappedMessageRow(guid: messageGUID) else {
            return jsonNull
        }

        let payloadRows = try messagePayloadRows(db: db, msgRows: [msgRow], threadID: threadID)
        let messages = try mapAndHashMessages(
            msgRows: [msgRow],
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
        guard let message = messages.first(where: { ($0["id"] as? String) == messageID }) else {
            return jsonNull
        }
        return try encodeJSON(message)
    }

    nonisolated static func searchMessages(
        db: IMDatabase,
        query: String,
        threadID publicThreadID: String?,
        mediaOnly: Bool,
        sender: String?,
        currentUserID: String,
        accountID: String,
        limit: Int? = nil
    ) throws -> String {
        let threadID = try publicThreadID.map { try originalThreadID(db: db, $0) }
        let effectiveLimit = limit ?? messagePageLimit
        let matchingRowIDs = try db.searchMessages(
            query: query,
            chatGUID: threadID,
            mediaOnly: mediaOnly,
            sender: sender,
            limit: effectiveLimit
        )
        guard !matchingRowIDs.isEmpty else {
            return try encodeJSON([
                "items": [],
                "hasMore": false,
                "oldestCursor": "",
            ])
        }

        let msgRows = try db.mappedMessageRows(rowIDs: matchingRowIDs)
        let attachmentRows = decorateAttachments(try db.mappedAttachmentRows(messageRowIDs: msgRows.compactMap { $0.int("ROWID") }))
        let messageGUIDs = msgRows.compactMap { $0.string("guid") }
        let reactionRows = try threadID.map { try db.mappedReactionRows(messageGUIDs: messageGUIDs, chatGUID: $0) } ?? []
        let messages = try mapAndHashMessages(
            msgRows: msgRows,
            attachmentRows: attachmentRows,
            reactionRows: reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
        return try encodeJSON([
            "items": messages,
            "hasMore": matchingRowIDs.count == effectiveLimit,
            "oldestCursor": msgRows.first?.string("date") ?? "",
        ])
    }
}

extension PlatformAPI {
    private struct MessagePayloadRows {
        var attachmentRows: [JSONObject]
        var reactionRows: [JSONObject]
    }

    nonisolated static func latestThreadMessageRowsByChatGUID(db: IMDatabase, chatRows: [JSONObject]) throws -> [String: JSONObject] {
        try db.mappedLatestMessageRows(chatRowIDs: chatRows.compactMap { $0.int("ROWID") })
    }

    nonisolated static func latestThreadMessagesByChatGUID(
        db: IMDatabase,
        _ latestMessageRowsByChatGUID: [String: JSONObject],
        currentUserID: String,
        accountID: String
    ) throws -> [String: [JSONObject]] {
        var latestMessagesByChatGUID = [String: [JSONObject]]()
        for (guid, msgRow) in latestMessageRowsByChatGUID {
            let payloadRows = try messagePayloadRows(db: db, msgRows: [msgRow], threadID: guid)
            latestMessagesByChatGUID[guid] = try mapAndHashMessages(
                msgRows: [msgRow],
                attachmentRows: payloadRows.attachmentRows,
                reactionRows: payloadRows.reactionRows,
                currentUserID: currentUserID,
                accountID: accountID
            )
        }
        return latestMessagesByChatGUID
    }

    nonisolated static func permanentDNDThreadIDs() -> Set<String> {
        Set((Defaults.getDNDList() ?? [:]).compactMap { key, value in
            value == Int(Date.distantFuture.timeIntervalSince1970) ? key : nil
        })
    }

    nonisolated static func originalThreadID(db: IMDatabase, _ threadID: String) throws -> String {
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

    private nonisolated static func messagePayloadRows(
        db: IMDatabase,
        msgRows: [JSONObject],
        threadID: String
    ) throws -> MessagePayloadRows {
        let msgRowIDs = msgRows.compactMap { $0.int("ROWID") }
        let msgGUIDs = msgRows.compactMap { $0.string("guid") }
        let chatRowID = msgRows.first?.int("chatRowID")
        return MessagePayloadRows(
            attachmentRows: decorateAttachments(try db.mappedAttachmentRows(messageRowIDs: msgRowIDs)),
            reactionRows: try chatRowID.map { try db.mappedReactionRows(messageGUIDs: msgGUIDs, chatRowID: $0) }
                ?? db.mappedReactionRows(messageGUIDs: msgGUIDs, chatGUID: threadID)
        )
    }

    nonisolated static func mapAndHashMessages(
        msgRows: [JSONObject],
        attachmentRows: [JSONObject],
        reactionRows: [JSONObject],
        currentUserID: String,
        accountID: String
    ) throws -> [JSONObject] {
        guard !msgRows.isEmpty else {
            return []
        }

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
