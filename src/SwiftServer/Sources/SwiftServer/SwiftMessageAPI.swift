import Foundation
import IMDatabase
import Logging
import NodeAPI
import SwiftServerFoundation

private let messagePageLimit = 20
private let platformLog = Logger(swiftServerLabel: "platform-api")
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

            let newDatabase = try IMDatabase(createIndexes: true)
            cachedDatabase = newDatabase
            return try action(newDatabase)
        }
    }
}

@NodeActor @NodeClass final class PlatformAPI {
    static let name = "PlatformAPI"

    private let accountID: String
    private let database = PlatformAPIDatabase()
    private let currentUserCache = Protected<CurrentUser?>()
    private let dndUserIDs = Protected(Set<String>())
    private var messagesControllerWrapper: MessagesControllerWrapper?
    private var hasBeenDisposed = false

    @NodeConstructor init(accountID: String) {
        self.accountID = accountID
    }

    private static func offNodeActor<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try action()
        }.value
    }

    nonisolated private static func currentUser(db: IMDatabase, cache: Protected<CurrentUser?>) throws -> CurrentUser {
        try cache.withLock { cachedUser in
            if let cachedUser {
                return cachedUser
            }

            let currentUser = try CurrentUser.fetch(from: db)
            cachedUser = currentUser
            return currentUser
        }
    }

    @NodeMethod func getMessages(threadID: String, cursor: String?, direction: String?, limit: Int?) async throws -> String {
        let accountID = accountID
        let database = database
        let currentUserCache = currentUserCache
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                let currentUserID = try Self.currentUser(db: db, cache: currentUserCache).id
                return try Self.getMessages(
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
        let accountID = accountID
        let database = database
        let currentUserCache = currentUserCache
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                let currentUserID = try Self.currentUser(db: db, cache: currentUserCache).id
                return try Self.getMessage(
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
        let accountID = accountID
        let database = database
        let currentUserCache = currentUserCache
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                let currentUserID = try Self.currentUser(db: db, cache: currentUserCache).id
                return try Self.getThreads(
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
        let accountID = accountID
        let database = database
        let currentUserCache = currentUserCache
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                let currentUserID = try Self.currentUser(db: db, cache: currentUserCache).id
                return try Self.getThread(
                    db: db,
                    threadID: threadID,
                    currentUserID: currentUserID,
                    accountID: accountID
                )
            }
        }
    }

    @NodeMethod func searchMessages(query: String, threadID: String?, mediaOnly: Bool?, sender: String?, limit: Int?) async throws -> String {
        let accountID = accountID
        let database = database
        let currentUserCache = currentUserCache
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                let currentUserID = try Self.currentUser(db: db, cache: currentUserCache).id
                return try Self.searchMessages(
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

    @NodeMethod func getCurrentUser() async throws -> String {
        let database = database
        let currentUserCache = currentUserCache
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                try jsonStringify(Self.currentUser(db: db, cache: currentUserCache).hashed())
            }
        }
    }

    @NodeMethod func getMessagesController(_ args: NodeArguments) async throws -> NodeValueConvertible {
        let forceInvalidate = args.count > 0 ? try args[0].as(Bool.self) ?? false : false
        return try await getMessagesControllerWrapper(forceInvalidate: forceInvalidate).wrapped()
    }

    @NodeMethod func notifyAnyway(threadID publicThreadID: String) async throws -> NodeValueConvertible {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        let wrapper = try await getMessagesControllerWrapper()
        return try wrapper.notifyAnyway(threadID: threadID)
    }

    private func getMessagesControllerWrapper(forceInvalidate: Bool = false) async throws -> MessagesControllerWrapper {
        guard !hasBeenDisposed else {
            throw ErrorMessage("PlatformAPI has been disposed")
        }

        if let existing = messagesControllerWrapper {
            let isValid = try await Self.onMessagesControllerQueue {
                existing.controller.isValid
            }
            if isValid && !forceInvalidate {
                return existing
            }

            platformLog.debug("disposing cached MessagesController (valid? \(isValid), invalidation forced? \(forceInvalidate))")
            try existing.dispose()
            messagesControllerWrapper = nil
        }

        let wrapper = try await makeMessagesControllerWrapper()
        guard !hasBeenDisposed else {
            try wrapper.dispose()
            throw ErrorMessage("PlatformAPI has been disposed")
        }

        messagesControllerWrapper = wrapper
        return wrapper
    }

    @NodeMethod func dispose() throws {
        hasBeenDisposed = true

        guard let wrapper = messagesControllerWrapper else {
            return
        }

        try wrapper.dispose()
        messagesControllerWrapper = nil
    }

    @NodeMethod func onThreadSelected(_ args: NodeArguments) throws -> NodeValueConvertible {
        guard args.count == 3,
              let publicThreadID = try args[0].as(String.self),
              let sendEvents = try args[1].as(NodeFunction.self),
              let messagesController = try args[2].as(MessagesControllerWrapper.self)
        else {
            throw ErrorMessage("Bad PlatformAPI call: \(#function)")
        }

        guard !publicThreadID.isEmpty else {
            return undefined
        }

        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }

        guard !Preferences.enabledExperiments.contains("no_watch_thread") else {
            return undefined
        }

        let singleParticipantID = singleParticipantAddress(threadID)
        platformLog.debug("activity/\(publicThreadID): watching")

        return try messagesController.watchThreadActivity(threadID: threadID) { [dndUserIDs] statuses in
            platformLog.debug("activity/\(publicThreadID): received \(statuses.map(\.rawValue))")

            let isDNDCanNotify = statuses.contains(.dndCanNotify)
            let isDND = statuses.contains(.dnd) || isDNDCanNotify
            let userID = threadIDToAddress(threadID) ?? ""
            if isDND {
                dndUserIDs.withLock { $0.insert(userID) }
            } else {
                dndUserIDs.withLock { $0.remove(userID) }
            }

            guard let singleParticipantID else {
                platformLog.debug("activity/\(publicThreadID): NOT syncing; not a single participant \(statuses.map(\.rawValue))")
                return
            }

            var events: [NodeValueConvertible] = [
                try NodeObject([
                    "type": "user_activity",
                    "activityType": statuses.contains(.typing) ? "typing" : "none",
                    "threadID": publicThreadID,
                    "participantID": Hasher.participant.tokenizeRemembering(pii: singleParticipantID),
                    "durationMs": 120_000,
                ])
            ]

            if isDND {
                events.append(try NodeObject([
                    "type": "user_presence_updated",
                    "presence": try NodeObject([
                        "userID": Hasher.participant.tokenizeRemembering(pii: userID),
                        "status": isDNDCanNotify ? "dnd_can_notify" : "dnd",
                    ]),
                ]))
            } else if dndUserIDs.withLock({ $0.contains(userID) }) {
                dndUserIDs.withLock { $0.remove(userID) }
                events.append(try NodeObject([
                    "type": "user_presence_updated",
                    "presence": try NodeObject([
                        "userID": Hasher.participant.tokenizeRemembering(pii: userID),
                        "status": "idle",
                    ]),
                ]))
            }

            try sendEvents.dynamicallyCall(withArguments: [try events.nodeValue()])
        }
    }

    private static func onMessagesControllerQueue<T>(
        _ action: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            MessagesControllerWrapper.queue.async {
                continuation.resume(with: Result { try action() })
            }
        }
    }

    private func makeMessagesControllerWrapper() async throws -> MessagesControllerWrapper {
        let q = try NodeAsyncQueue(label: "platform-api-messages-controller")
        let controller = try await Self.onMessagesControllerQueue {
            try MessagesController(reportToSentry: { txt in
                platformLog.error("<!> report to sentry: \(txt)")
                try? q.run {
                    try Node.texts.Sentry.captureMessage(txt)
                }
            })
        }
        return try MessagesControllerWrapper(controller: controller)
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
