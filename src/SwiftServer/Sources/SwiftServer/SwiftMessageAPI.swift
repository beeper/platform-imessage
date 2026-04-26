import Foundation
import IMDatabase
import Logging
import NodeAPI
import SwiftServerFoundation

private let messagePageLimit = 20
private let platformLog = Logger(swiftServerLabel: "platform-api")
private let messageSendTimeout: TimeInterval = 45
private let reactionSendTimeout: TimeInterval = 5
private let waitForLinksTimeout: TimeInterval = 1.5
private let waitForSentThreadTimeout: TimeInterval = 10
private let sentMessagePollInterval: TimeInterval = 0.025
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

    @NodeMethod func getMessagesController(forceInvalidate: Bool?) async throws -> NodeValueConvertible {
        try await getMessagesControllerWrapper(forceInvalidate: forceInvalidate ?? false).wrapped()
    }

    @NodeMethod func createThread(addresses addressesValue: NodeArray, title: String?, message: String?) async throws -> String {
        let addresses = try addressesValue.as([String].self).orThrow(ErrorMessage("Bad PlatformAPI call: \(#function)"))

        guard !addresses.isEmpty else {
            return "false"
        }

        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ErrorMessage("no message")
        }

        if addresses.count == 1 {
            let existingThreadID = "\(isTahoeOrUp ? "any" : "iMessage");-;\(addresses[0])"
            let accountID = accountID
            let database = database
            let currentUserCache = currentUserCache
            let existingThread = try await Self.offNodeActor {
                try database.withDatabase { db in
                    let currentUserID = try Self.currentUser(db: db, cache: currentUserCache).id
                    return try Self.getThread(
                        db: db,
                        threadID: existingThreadID,
                        currentUserID: currentUserID,
                        accountID: accountID
                    )
                }
            }

            if existingThread != jsonNull {
                let wrapper = try await getMessagesControllerWrapper()
                try await Self.onMessagesControllerQueue {
                    try wrapper.controller.sendMessage(
                        threadID: existingThreadID,
                        addresses: nil,
                        text: message,
                        filePath: nil,
                        quotedMessage: nil
                    )
                }
                return existingThread
            }
        }

        let wrapper = try await getMessagesControllerWrapper()
        try await Self.onMessagesControllerQueue {
            try wrapper.controller.sendMessage(
                threadID: nil,
                addresses: addresses,
                text: message,
                filePath: nil,
                quotedMessage: nil
            )
        }
        return "true"
    }

    @NodeMethod func sendMessage(threadID publicThreadID: String, text: String?, filePath: String?, quotedMessageID: String?) async throws -> String {
        let database = database
        let threadID = try await Self.offNodeActor {
            try database.withDatabase { db in
                try Self.originalThreadID(db: db, publicThreadID)
            }
        }

        if threadID.hasPrefix("SMS;-;"), threadID.contains("@") {
            throw ErrorMessage("Cannot send message to email address over SMS")
        }

        let lastRowID = try await performControllerOperation(
            name: "sendMessage",
            retries: quotedMessageID == nil ? 1 : 2,
            prepareAttempt: { try await self.lastMessageRowID() }
        ) { wrapper in
            try wrapper.performSendMessage(
                threadID: threadID,
                text: text,
                filePath: filePath,
                quotedMessageID: quotedMessageID
            )
        }

        return try await waitForMessageSend(
            threadID: threadID,
            expectedLinkedMessageID: quotedMessageID,
            text: text,
            lastRowID: lastRowID,
            timeout: messageSendTimeout
        )
    }

    @NodeMethod func setReaction(threadID publicThreadID: String, messageID: String, reaction: String, on: Bool) async throws -> NodeValueConvertible {
        if reaction == "sticker" {
            throw ErrorMessage(on ? "Adding sticker reactions isn't supported" : "Removing sticker reactions isn't supported")
        }

        let database = database
        let threadID = try await Self.offNodeActor {
            try database.withDatabase { db in
                try Self.originalThreadID(db: db, publicThreadID)
            }
        }

        try await retryReactionOperation(threadID: threadID, messageID: messageID, reaction: reaction, on: on)
        return undefined
    }

    @NodeMethod func notifyAnyway(threadID publicThreadID: String) async throws -> NodeValueConvertible {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        let wrapper = try await getMessagesControllerWrapper()
        return try wrapper.notifyAnyway(threadID: threadID)
    }

    @NodeMethod func deleteMessage(threadID publicThreadID: String, messageID: String) async throws -> NodeValueConvertible {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        let wrapper = try await getMessagesControllerWrapper()
        return try wrapper.undoSend(threadID: threadID, messageID: messageID)
    }

    @NodeMethod func editMessage(threadID publicThreadID: String, messageID: String, newText text: String?) async throws -> NodeValueConvertible {
        guard isVenturaOrUp else {
            throw ErrorMessage("Only supported on macOS Ventura or later")
        }

        guard let text, !text.isEmpty else {
            throw ErrorMessage("Tried to edit message to have empty content")
        }

        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        let wrapper = try await getMessagesControllerWrapper()
        return try wrapper.editMessage(threadID: threadID, messageID: messageID, newText: text)
    }

    @NodeMethod func deleteThread(threadID publicThreadID: String) async throws -> NodeValueConvertible {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        let wrapper = try await getMessagesControllerWrapper()
        return try wrapper.deleteThread(threadID: threadID)
    }

    @NodeMethod func sendActivityIndicator(type: String, threadID publicThreadID: String?, sendingMessagesCount: Int?) async throws -> NodeValueConvertible {
        guard let publicThreadID, !publicThreadID.isEmpty else {
            platformLog.error("ignoring request to send an activity indicator, no thread id provided")
            return undefined
        }

        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }

        guard type == "typing" || type == "none" else {
            return undefined
        }

        guard (sendingMessagesCount ?? 0) == 0 else {
            platformLog.debug("skipping sendActivityIndicator")
            return undefined
        }

        // Group chat typing indicators require Tahoe+.
        guard isTahoeOrUp || singleParticipantAddress(threadID) != nil else {
            return undefined
        }

        let wrapper = try await getMessagesControllerWrapper()
        return try wrapper.sendTypingStatus(threadID: threadID, isTyping: type == "typing")
    }

    @NodeMethod func markAsUnread(threadID publicThreadID: String) async throws -> NodeValueConvertible {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        let wrapper = try await getMessagesControllerWrapper()
        return try wrapper.toggleThreadRead(threadID: threadID, read: false)
    }

    @NodeMethod func sendReadReceipt(threadID publicThreadID: String) async throws -> NodeValueConvertible {
        let database = database
        let (threadID, isRead) = try await Self.offNodeActor {
            try database.withDatabase { db in
                let threadID = try Self.originalThreadID(db: db, publicThreadID)
                return (threadID, try db.isThreadRead(chatGUID: threadID))
            }
        }
        guard !isRead else {
            return undefined
        }

        let wrapper = try await getMessagesControllerWrapper()
        let controller = wrapper.controller
        try await Self.onMessagesControllerQueue {
            try controller.toggleThreadRead(threadID: threadID, read: true)
        }
        return undefined
    }

    @NodeMethod func getAsset(pathHex: String, methodName: String?) async throws -> NodeValueConvertible {
        let database = database
        let asset = try await Self.offNodeActor {
            try Self.getAsset(db: database, pathHex: pathHex, methodName: methodName ?? "")
        }
        switch asset {
        case let .url(url):
            return url
        case let .data(data):
            return data
        }
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

    @NodeMethod func onThreadSelected(_ args: NodeArguments) async throws -> NodeValueConvertible {
        guard args.count == 2,
              let publicThreadID = try args[0].as(String.self),
              let sendEvents = try args[1].as(NodeFunction.self)
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

        let messagesController = try await getMessagesControllerWrapper()
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

    @discardableResult
    private func performControllerOperation<AttemptContext>(
        name: String,
        retries: Int,
        prepareAttempt: @escaping @Sendable () async throws -> AttemptContext,
        _ action: @escaping @Sendable (MessagesControllerWrapper) throws -> Void,
        afterAttempt: (@Sendable (AttemptContext) async throws -> Void)? = nil
    ) async throws -> AttemptContext {
        var attempt = 0
        while true {
            do {
                let context = try await prepareAttempt()
                let wrapper = try await getMessagesControllerWrapper(forceInvalidate: attempt > 0)
                try await Self.onMessagesControllerQueue {
                    try action(wrapper)
                }
                try await afterAttempt?(context)
                return context
            } catch {
                platformLog.error("\(name) failed, retries left: \(max(retries - attempt, 0)): \(error)")
                try? await reportMessageToSentry("imessage \(name) failed: \(error)")
                guard attempt < retries else {
                    throw error
                }
                attempt += 1
            }
        }
    }

    private func retryReactionOperation(threadID: String, messageID: String, reaction: String, on: Bool) async throws {
        try await performControllerOperation(
            name: "setReaction",
            retries: 2,
            prepareAttempt: { try await self.lastMessageRowID() }
        ) { wrapper in
            try wrapper.performSetReaction(threadID: threadID, messageID: messageID, reactionName: reaction, on: on)
        } afterAttempt: { lastRowID in
            _ = try await self.waitForMessageSend(
                threadID: threadID,
                expectedLinkedMessageID: messageID,
                text: nil,
                lastRowID: lastRowID,
                timeout: reactionSendTimeout
            )
        }
    }

    private func lastMessageRowID() async throws -> Int {
        let database = database
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                try db.lastMessageRowID()
            }
        }
    }

    private func waitForMessageSend(
        threadID: String,
        expectedLinkedMessageID: String?,
        text: String?,
        lastRowID: Int,
        timeout: TimeInterval
    ) async throws -> String {
        let sentMessageIDs = try await waitForSentMessageIDs(since: lastRowID, text: text, timeout: timeout)
        let sentThreadIDs = try await waitForSentThreadIDs(messageRowIDs: sentMessageIDs.map(\.rowID))
        let wrapper = try await getMessagesControllerWrapper()
        let address = threadIDToAddress(threadID)
        let sentThreadIsValid = try await Self.onMessagesControllerQueue {
            sentThreadIDs.allSatisfy { sentThreadID in
                sentThreadID == threadID || (
                    sentThreadID != nil
                    && wrapper.controller.isSameContact(address, threadIDToAddress(sentThreadID!))
                )
            }
        }

        guard sentThreadIsValid else {
            platformLog.error("imsg: imessage potentially sent messages to invalid thread")
            return "true"
        }

        let messages = try await sentMessages(sentMessageIDs)
        validateLinkedMessageIDs(messages, expectedLinkedMessageID: expectedLinkedMessageID)
        return try Self.encodeJSON(messages)
    }

    private func waitForSentMessageIDs(
        since lastRowID: Int,
        text: String?,
        timeout: TimeInterval
    ) async throws -> [(rowID: Int, guid: String)] {
        let database = database
        return try await Self.offNodeActor {
            let start = Date()
            let expectedNewMessageIDCount = text.map { max(linkCount(in: $0), 1) } ?? 1
            var sentMessageIDs: [(rowID: Int, guid: String)] = []
            while sentMessageIDs.count != expectedNewMessageIDCount {
                sentMessageIDs = try database.withDatabase { db in
                    try db.sentMessageIDs(since: lastRowID)
                }
                if text != nil, !sentMessageIDs.isEmpty, Date().timeIntervalSince(start) > waitForLinksTimeout {
                    break
                }
                if Date().timeIntervalSince(start) > timeout {
                    throw ErrorMessage("timed out waiting for sent messages")
                }
                Thread.sleep(forTimeInterval: sentMessagePollInterval)
            }
            return sentMessageIDs
        }
    }

    private func waitForSentThreadIDs(messageRowIDs: [Int]) async throws -> [String?] {
        let database = database
        return try await Self.offNodeActor {
            let sentThreadIDs = {
                try messageRowIDs.map { rowID in
                    try database.withDatabase { db in
                        try db.threadIDForMessage(rowID: rowID)
                    }
                }
            }
            var threadIDs = try sentThreadIDs()
            let start = Date()
            while threadIDs.contains(where: { $0 == nil }) {
                Thread.sleep(forTimeInterval: sentMessagePollInterval)
                threadIDs = try sentThreadIDs()
                if Date().timeIntervalSince(start) > waitForSentThreadTimeout {
                    break
                }
            }
            return threadIDs
        }
    }

    private func sentMessages(_ sentMessageIDs: [(rowID: Int, guid: String)]) async throws -> [JSONObject] {
        let accountID = accountID
        let database = database
        let currentUserCache = currentUserCache
        return try await Self.offNodeActor {
            try database.withDatabase { db in
                let currentUserID = try Self.currentUser(db: db, cache: currentUserCache).id
                var messages = [JSONObject]()
                for sentMessageID in sentMessageIDs {
                    guard let message = try Self.messageObject(
                        db: db,
                        threadID: nil,
                        messageID: sentMessageID.guid,
                        currentUserID: currentUserID,
                        accountID: accountID
                    ) else {
                        continue
                    }
                    messages.append(message)
                }
                return messages
            }
        }
    }

    private func validateLinkedMessageIDs(_ messages: [JSONObject], expectedLinkedMessageID: String?) {
        for message in messages where message.bool("isHidden") != true {
            let actual = message.string("linkedMessageID")
            guard expectedLinkedMessageID != actual else {
                continue
            }
            platformLog.error("imsg: sent message with incorrect quoted message, intended: \(String(describing: expectedLinkedMessageID)), actual: \(String(describing: actual))")
            Task {
                try? await reportMessageToSentry("imessage sent message with incorrect quoted message, intended=\(expectedLinkedMessageID != nil) actual=\(actual != nil)")
            }
        }
    }

    private func reportMessageToSentry(_ message: String) async throws {
        try await Node.texts.Sentry.captureMessage(message)
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
        try messageObject(
            db: db,
            threadID: publicThreadID,
            messageID: messageID,
            currentUserID: currentUserID,
            accountID: accountID
        ).map(encodeJSON) ?? jsonNull
    }

    nonisolated static func messageObject(
        db: IMDatabase,
        threadID publicThreadID: String?,
        messageID: String,
        currentUserID: String,
        accountID: String
    ) throws -> JSONObject? {
        let threadID = try publicThreadID.map { try originalThreadID(db: db, $0) }
        let messageGUID = messageID.components(separatedBy: "_").first ?? messageID
        guard let msgRow = try db.mappedMessageRow(guid: messageGUID) else {
            return nil
        }

        let payloadRows = try messagePayloadRows(db: db, msgRows: [msgRow], threadID: threadID ?? "")
        let messages = try mapAndHashMessages(
            msgRows: [msgRow],
            attachmentRows: payloadRows.attachmentRows,
            reactionRows: payloadRows.reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
        return messages.first(where: { ($0["id"] as? String) == messageID })
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

    private enum AssetResult: Sendable {
        case url(String)
        case data(Data)
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
        let msgRows = Array(latestMessageRowsByChatGUID.values)
        let payloadRows = try messagePayloadRows(db: db, msgRows: msgRows, threadID: "")
        let attachmentRowsByMessageID = Dictionary(grouping: payloadRows.attachmentRows, by: { $0.int("msgRowID") ?? -1 })
        let reactionRowsByMessageGUID = Dictionary(grouping: payloadRows.reactionRows, by: { reactionMessageGUID($0.string("associated_message_guid") ?? "") })

        var latestMessagesByChatGUID = [String: [JSONObject]]()
        for (guid, msgRow) in latestMessageRowsByChatGUID {
            latestMessagesByChatGUID[guid] = try mapAndHashMessage(
                msgRow: msgRow,
                attachmentRows: attachmentRowsByMessageID[msgRow.int("ROWID") ?? -1] ?? [],
                reactionRows: reactionRowsByMessageGUID[msgRow.string("guid") ?? ""] ?? [],
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
        guard !msgRows.isEmpty else {
            return MessagePayloadRows(attachmentRows: [], reactionRows: [])
        }

        let msgRowIDs = msgRows.compactMap { $0.int("ROWID") }
        let msgGUIDs = msgRows.compactMap { $0.string("guid") }
        let chatRowIDs = Array(Set(msgRows.compactMap { $0.int("chatRowID") }))
        let reactionRows: [JSONObject]
        if !chatRowIDs.isEmpty {
            reactionRows = try db.mappedReactionRows(messageGUIDs: msgGUIDs, chatRowIDs: chatRowIDs)
        } else {
            reactionRows = try db.mappedReactionRows(messageGUIDs: msgGUIDs, chatGUID: threadID)
        }
        return MessagePayloadRows(
            attachmentRows: decorateAttachments(try db.mappedAttachmentRows(messageRowIDs: msgRowIDs)),
            reactionRows: reactionRows
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
            try mapAndHashMessage(
                msgRow: msgRow,
                attachmentRows: attachmentRowsByMessageID[msgRow.int("ROWID") ?? -1] ?? [],
                reactionRows: reactionRowsByMessageGUID[msgRow.string("guid") ?? ""] ?? [],
                currentUserID: currentUserID,
                accountID: accountID
            )
        }
    }

    nonisolated static func mapAndHashMessage(
        msgRow: JSONObject,
        attachmentRows: [JSONObject],
        reactionRows: [JSONObject],
        currentUserID: String,
        accountID: String
    ) throws -> [JSONObject] {
        let mapper = Mapper(
            msgRow: msgRow,
            attachmentRows: attachmentRows,
            reactionRows: reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
        let mapped = try mapper.mapMessage().filter { shouldKeepForAPI($0) }
        return attachOriginalIfNeeded(
            mapped,
            msgRow: msgRow,
            attachmentRows: attachmentRows,
            currentUserID: currentUserID
        ).map(hashMessage)
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

    private nonisolated static func getAsset(db database: PlatformAPIDatabase, pathHex: String, methodName: String) throws -> AssetResult {
        switch pathHex {
        case "hw":
            let uuid = methodName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? methodName
            let fileNames = try FileManager.default.contentsOfDirectory(atPath: temporaryMobileSMSPath)
            var attemptsRemaining = 10
            while attemptsRemaining > 0 {
                attemptsRemaining -= 1
                if let fileName = fileNames.first(where: { $0.hasPrefix("hw_\(uuid)_") }) {
                    return .url(fileURLString(temporaryMobileSMSURL.appendingPathComponent(fileName).path))
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw ErrorMessage("Couldn't fetch handwriting asset")

        case "dt":
            let uuid = methodName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? methodName
            let filePath = temporaryMobileSMSURL.appendingPathComponent("\(uuid).mov").path
            _ = waitForFileToExist(filePath, maxWait: 5)
            return .url(fileURLString(filePath))

        case "reaction-sticker":
            let rowIDString = methodName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? methodName
            guard let rowID = Int(rowIDString) else {
                throw ErrorMessage("invalid reaction sticker row ID")
            }
            let filePath = try database.withDatabase { db in
                try db.attachmentFilename(messageRowID: rowID).map(replaceTilde)
            }
            guard let filePath else {
                throw ErrorMessage("couldn't resolve sticker attachment for reaction row")
            }
            return .url(fileURLString(filePath))

        case "thread-image":
            let filePath = try database.withDatabase { db in
                try db.attachmentFilename(guid: methodName).map(replaceTilde)
            }
            guard let filePath else {
                throw ErrorMessage("couldn't resolve chat image attachment")
            }
            return .url(fileURLString(filePath))

        default:
            let filePath = try String(
                data: Data([UInt8](hexString: pathHex)),
                encoding: .utf8
            ).orThrow(ErrorMessage("couldn't decode asset path"))
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            guard let pngData = CgBIPNG.dataForAsset(data) else {
                return .url(fileURLString(filePath))
            }
            return .data(pngData)
        }
    }

    nonisolated static func encodeJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try String(data: data, encoding: .utf8).orThrow(ErrorMessage("Swift message API output wasn't utf8"))
    }
}
