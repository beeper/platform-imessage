import Foundation
import IMDatabase
import Logging
import IMessageCore

private let messagePageLimit = 20
private let platformLog = Logger(imessageLabel: "platform-api")
private let messageSendTimeout: TimeInterval = 45
private let reactionSendTimeout: TimeInterval = 5
private let waitForLinksTimeout: TimeInterval = 1.5
private let waitForSentThreadTimeout: TimeInterval = 10
private let sentMessagePollInterval: TimeInterval = 0.025

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

public final class PlatformAPI {
    private let runtime: Runtime
    private var messagesControllerCleanupHook: CleanupHook?
    private var watchCBQueue: CallbackQueue?

    private let accountID: String

    private let database = PlatformAPIDatabase()
    private let currentUserCache = Protected<CurrentUser?>()
    private let dndUserIDs = Protected(Set<String>())

    private var messagesController: MessagesController?

    private let threadObserveRequestToken = Protected<UUID?>()
    private let hasBeenDisposed = Protected(false)

    private static let messagesControllerQueue = PassivelyAwareDispatchQueue(label: "messages-controller-platform-queue", idleDelay: 1)

    public convenience init(accountID: String) {
        self.init(accountID: accountID, runtime: .noop)
    }

    public init(accountID: String, runtime: Runtime) {
        self.accountID = accountID
        self.runtime = runtime
    }

    /// Runs a DB query off the caller actor with the cached current user resolved.
    /// Captures `accountID`, `database`, and `currentUserCache` before crossing
    /// into the @Sendable closure so `self` doesn't need to.
    private func runDBQuery<T>(
        _ work: @escaping @Sendable (IMDatabase, CurrentUser, String /*accountID*/) throws -> T
    ) async throws -> T {
        let accountID = accountID
        let database = database
        let currentUserCache = currentUserCache
        return try await Task.detached(priority: .userInitiated) {
            try database.withDatabase { db in
                let currentUser = try Self.currentUser(db: db, cache: currentUserCache)
                return try work(db, currentUser, accountID)
            }
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

    public func getCurrentUser() async throws -> String {
        let database = database
        let currentUserCache = currentUserCache
        return try await DetachedWork.run {
            try database.withDatabase { db in
                try jsonStringify(Self.currentUser(db: db, cache: currentUserCache).hashed())
            }
        }
    }

    public func searchMessages(typed: String, threadID: String?, mediaOnly: Bool?, sender: String?, limit: Int?) async throws -> String {
        let page = try await runDBQuery { db, currentUser, accountID in
            try Self.searchMessages(
                db: db,
                query: typed,
                threadID: threadID,
                mediaOnly: mediaOnly ?? false,
                sender: sender,
                currentUserID: currentUser.id,
                accountID: accountID,
                limit: limit
            )
        }
        return try encodeJSON(page.jsonObject)
    }

    public func getThreads(folderName: String, cursor: String?, direction: String?) async throws -> PlatformAPIPage<PlatformAPIThread> {
        try await runDBQuery { db, currentUser, accountID in
            try Self.getThreads(
                db: db,
                folderName: folderName,
                cursor: cursor,
                direction: direction,
                currentUser: currentUser,
                accountID: accountID
            )
        }
    }

    public func getMessages(threadID: String, cursor: String?, direction: String?, limit: Int?) async throws -> PlatformAPIPage<PlatformAPIMessage> {
        try await runDBQuery { db, currentUser, accountID in
            try Self.getMessages(
                db: db,
                threadID: threadID,
                cursor: cursor,
                direction: direction,
                currentUserID: currentUser.id,
                accountID: accountID,
                limit: limit
            )
        }
    }

    public func getThread(threadID: String) async throws -> PlatformAPIThread? {
        try await runDBQuery { db, currentUser, accountID in
            try Self.getThread(
                db: db,
                threadID: threadID,
                currentUser: currentUser,
                accountID: accountID
            )
        }
    }

    public func getMessage(threadID: String, messageID: String) async throws -> PlatformAPIMessage? {
        try await runDBQuery { db, currentUser, accountID in
            try Self.getMessage(
                db: db,
                threadID: threadID,
                messageID: messageID,
                currentUserID: currentUser.id,
                accountID: accountID
            )
        }
    }

    public func createThread(userIDs: [String], title: String?, messageText: String?) async throws -> String {
        guard !userIDs.isEmpty else {
            return "false"
        }

        guard let messageText, !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ErrorMessage("no message")
        }

        if userIDs.count == 1 {
            let existingThreadID = "\(isTahoeOrUp ? "any" : "iMessage");-;\(userIDs[0])"
            let existingThread = try await runDBQuery { db, currentUser, accountID in
                try Self.getThread(
                    db: db,
                    threadID: existingThreadID,
                    currentUser: currentUser,
                    accountID: accountID
                )
            }

            if let existingThread {
                let controller = try await getMessagesController()
                try await Self.onMessagesControllerQueue {
                    try controller.sendMessage(
                        threadID: existingThreadID,
                        addresses: nil,
                        text: messageText,
                        filePath: nil,
                        quotedMessage: nil
                    )
                }
                return try encodeJSON(existingThread.jsonObject)
            }
        }

        let controller = try await getMessagesController()
        try await Self.onMessagesControllerQueue {
            try controller.sendMessage(
                threadID: nil,
                addresses: userIDs,
                text: messageText,
                filePath: nil,
                quotedMessage: nil
            )
        }
        return "true"
    }

    public func updateThread(threadID publicThreadID: String, muted: Bool) async throws {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        try await performOnController { try $0.muteThread(threadID: threadID, muted: muted) }
    }

    public func deleteThread(threadID publicThreadID: String) async throws {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        try await performOnController { try $0.deleteThread(threadID: threadID) }
    }

    public func sendMessage(threadID publicThreadID: String, text: String?, filePath: String?, quotedMessageID: String?) async throws -> String {
        let database = database
        let threadID = try await DetachedWork.run {
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
        ) { controller in
            try controller.sendMessage(
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

    public func sendFileFromBuffer(threadID publicThreadID: String, fileBuffer: Data, fileName: String?, quotedMessageID: String?) async throws -> String {
        let filePath = try await DetachedWork.run {
            try Self.writeTemporaryAttachmentFile(data: fileBuffer, fileName: fileName)
        }
        return try await sendMessage(threadID: publicThreadID, text: nil, filePath: filePath, quotedMessageID: quotedMessageID)
    }

    public func editMessage(threadID publicThreadID: String, messageID: String, content text: String?) async throws {
        guard isVenturaOrUp else {
            throw ErrorMessage("Only supported on macOS Ventura or later")
        }

        guard let text, !text.isEmpty else {
            throw ErrorMessage("Tried to edit message to have empty content")
        }

        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        try await performOnController { try $0.editMessage(threadID: threadID, messageID: messageID, newText: text) }
    }

    public func sendActivityIndicator(type: String, threadID publicThreadID: String?, sendingMessagesCount: Int?) async throws {
        guard let publicThreadID, !publicThreadID.isEmpty else {
            platformLog.error("ignoring request to send an activity indicator, no thread id provided")
            return
        }

        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }

        guard type == "typing" || type == "none" else {
            return
        }

        guard (sendingMessagesCount ?? 0) == 0 else {
            platformLog.debug("skipping sendActivityIndicator")
            return
        }

        // Group chat typing indicators require Tahoe+.
        guard isTahoeOrUp || singleParticipantAddress(threadID) != nil else {
            return
        }

        try await performOnController { controller in
            if type == "typing" {
                try controller.sendTypingStatus(threadID: threadID)
            } else {
                try controller.clearTypingStatus()
            }
        }
    }

    public func deleteMessage(threadID publicThreadID: String, messageID: String) async throws {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        try await performOnController { try $0.undoSend(threadID: threadID, messageID: messageID) }
    }

    public func sendReadReceipt(threadID publicThreadID: String) async throws {
        let database = database
        try await retry(retries: 1, interval: 1) { attempt in
            let (threadID, isRead) = try await DetachedWork.run {
                try database.withDatabase { db in
                    let threadID = try Self.originalThreadID(db: db, publicThreadID)
                    return (threadID, try db.isThreadRead(chatGUID: threadID))
                }
            }
            guard !isRead else {
                return
            }

            try await performOnController(forceInvalidate: attempt > 0) {
                try $0.toggleThreadRead(threadID: threadID, read: true)
            }
        } onError: { _, retriesLeft, error in
            platformLog.error("sendReadReceipt failed, retries left: \(retriesLeft): \(error)")
            try? self.reportMessageToSentry("imessage sendReadReceipt failed: \(error)")
        }
    }

    public func addReaction(threadID publicThreadID: String, messageID: String, reactionKey: String) async throws {
        try await setReaction(threadID: publicThreadID, messageID: messageID, reaction: reactionKey, on: true)
    }

    public func removeReaction(threadID publicThreadID: String, messageID: String, reactionKey: String) async throws {
        try await setReaction(threadID: publicThreadID, messageID: messageID, reaction: reactionKey, on: false)
    }

    public func setReaction(threadID publicThreadID: String, messageID: String, reaction: String, on: Bool) async throws {
        if reaction == "sticker" {
            throw ErrorMessage(on ? "Adding sticker reactions isn't supported" : "Removing sticker reactions isn't supported")
        }

        let database = database
        let threadID = try await DetachedWork.run {
            try database.withDatabase { db in
                try Self.originalThreadID(db: db, publicThreadID)
            }
        }

        try await retryReactionOperation(threadID: threadID, messageID: messageID, reaction: reaction, on: on)
    }

    public func markAsUnread(threadID publicThreadID: String) async throws {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        try await performOnController { try $0.toggleThreadRead(threadID: threadID, read: false) }
    }

    public func notifyAnyway(threadID publicThreadID: String) async throws {
        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }
        try await performOnController { try $0.notifyAnyway(threadID: threadID) }
    }

    public func onThreadSelected(threadID publicThreadID: String, sendEvents: @escaping EventSender) async throws {
        guard !publicThreadID.isEmpty else {
            return
        }

        let threadID = try database.withDatabase { db in
            try Self.originalThreadID(db: db, publicThreadID)
        }

        guard !Preferences.enabledExperiments.contains("no_watch_thread") else {
            return
        }

        let singleParticipantID = singleParticipantAddress(threadID)
        platformLog.debug("activity/\(publicThreadID): watching")

        try await watchThreadActivity(threadID: threadID) { [dndUserIDs] statuses in
            platformLog.debug("activity/\(publicThreadID): received \(statuses.map(\.rawValue))")

            let isDNDCanNotify = statuses.contains(.dndCanNotify)
            let isDND = statuses.contains(.dnd) || isDNDCanNotify
            let userID = threadIDToAddress(threadID) ?? ""
            if isDND {
                dndUserIDs.withLock {
                    _ = $0.insert(userID)
                }
            } else {
                dndUserIDs.withLock {
                    _ = $0.remove(userID)
                }
            }

            guard let singleParticipantID else {
                platformLog.debug("activity/\(publicThreadID): NOT syncing; not a single participant \(statuses.map(\.rawValue))")
                return
            }

            var events: [Event] = [
                [
                    "type": "user_activity",
                    "activityType": statuses.contains(.typing) ? "typing" : "none",
                    "threadID": publicThreadID,
                    "participantID": Hasher.participant.tokenizeRemembering(pii: singleParticipantID),
                    "durationMs": 120_000,
                ]
            ]

            if isDND {
                events.append([
                    "type": "user_presence_updated",
                    "presence": [
                        "userID": Hasher.participant.tokenizeRemembering(pii: userID),
                        "status": isDNDCanNotify ? "dnd_can_notify" : "dnd",
                    ],
                ])
            } else if dndUserIDs.withLock({ $0.contains(userID) }) {
                dndUserIDs.withLock {
                    _ = $0.remove(userID)
                }
                events.append([
                    "type": "user_presence_updated",
                    "presence": [
                        "userID": Hasher.participant.tokenizeRemembering(pii: userID),
                        "status": "idle",
                    ],
                ])
            }

            try sendEvents(events)
        }
    }

    public func getAsset(pathHex: String, methodName: String?) async throws -> AssetResult {
        let database = database
        return try await DetachedWork.run {
            try Self.getAsset(db: database, pathHex: pathHex, methodName: methodName ?? "")
        }
    }

    public func dispose() async throws {
        defer {
            Self.cleanupTemporaryAttachmentDirectory()
        }

        hasBeenDisposed.withLock { $0 = true }
        // OV2.A: clear cached current-user (and the Hasher tokens it implies)
        // and tear down polling so a logout/relogin in Messages.app while
        // Beeper restarts the account doesn't reuse stale state.
        currentUserCache.withLock { $0 = nil }
        SystemSettingsOnboarding.stop()
        await PollingLifecycle.shared.cancelPollingIfNecessary(clearEventCallback: true)
        try await disposeCachedMessagesController()
    }

    private func performOnController(
        forceInvalidate: Bool = false,
        _ action: @escaping @Sendable (MessagesController) throws -> Void
    ) async throws {
        let controller = try await getMessagesController(forceInvalidate: forceInvalidate)
        try await Self.onMessagesControllerQueue { try action(controller) }
    }

    private func getMessagesController(forceInvalidate: Bool = false) async throws -> MessagesController {
        guard !hasBeenDisposed.read() else {
            throw ErrorMessage("PlatformAPI has been disposed")
        }

        if let existing = messagesController {
            let isValid = try await Self.onMessagesControllerQueue {
                existing.isValid
            }
            if isValid && !forceInvalidate {
                return existing
            }

            platformLog.debug("disposing cached MessagesController (valid? \(isValid), invalidation forced? \(forceInvalidate))")
            try await disposeCachedMessagesController()
        }

        let controller = try await makeMessagesController()
        let cleanupHook = try await runtime.addCleanupHook { completion in
            Log.default.notice("[PlatformAPI] running MessagesController dispose inside cleanup hook")
            controller.dispose()
            completion()
        }

        guard !hasBeenDisposed.read() else {
            try await disposeMessagesController(controller, cleanupHook: cleanupHook)
            throw ErrorMessage("PlatformAPI has been disposed")
        }

        messagesController = controller
        messagesControllerCleanupHook = cleanupHook
        return controller
    }

    private func disposeCachedMessagesController() async throws {
        guard let controller = messagesController else {
            return
        }

        let cleanupHook = messagesControllerCleanupHook
        messagesController = nil
        messagesControllerCleanupHook = nil
        try await disposeMessagesController(controller, cleanupHook: cleanupHook)
    }

    /// Disposes a controller. Clears the queue's idle callback and runs
    /// `controller.dispose()` inside the same `queue.sync` critical section
    /// so a pending idle callback can't fire against a half-disposed controller.
    private func disposeMessagesController(_ controller: MessagesController, cleanupHook: CleanupHook?) async throws {
        Log.default.notice("[PlatformAPI] disposing MessagesController")
        Self.messagesControllerQueue.queue.sync {
            Self.messagesControllerQueue.setIdleCallback(nil)
            controller.dispose()
        }
        try await cleanupHook?.remove()
    }

    private func watchThreadActivity(
        threadID: String,
        statusSender: @escaping @Sendable ([ActivityStatus]) throws -> Void
    ) async throws {
        guard Defaults.imessage.bool(forKey: DefaultsKeys.watchThreadActivity) else {
            return
        }

        // reset the idle callback in case we fail and bail out
        Self.messagesControllerQueue.setIdleCallback(nil)

        let controller = try await getMessagesController()

        // only watch thread activity for iMessage chats
        // TODO: implement this for groups
        if !threadID.hasPrefix("iMessage;-;") {
            guard threadID.hasPrefix("any;-;") else {
                // only bother checking the database if the GUID can't tell us what service the chat is for
                // (can happen seemingly since macOS 26, which can use "any" as a universal GUID prefix)
                #if DEBUG
                platformLog.debug("chat isn't an iMessage 1:1 DM, not watching for activity")
                #endif
                return
            }

            let chat = try controller.db.chat(withGUID: threadID)
            guard let chat else {
                platformLog.error("watchThreadActivity: couldn't locate the chat to watch in the database")
                return
            }

            guard chat.serviceName == .imessage else {
                #if DEBUG
                platformLog.debug("chat definitely isn't an iMessage 1:1 DM, not watching for activity")
                #endif
                return
            }
        }

        let watchCBQueue: CallbackQueue
        if let existing = self.watchCBQueue {
            watchCBQueue = existing
        } else {
            watchCBQueue = try await runtime.makeCallbackQueue("watch-imessage-callback")
            self.watchCBQueue = watchCBQueue
        }
        let sendStatusOnQueue = { (statuses: [ActivityStatus]) in
            try? watchCBQueue.run {
                try statusSender(statuses)
            }
            return
        }

        // it's okay that we aren't using `onMessagesControllerQueue` here -
        // the idle callback is itself submitted onto the queue, so everything's
        // still serial
        let observe = try controller.idleCallback(observingThreadID: threadID, statusSender: sendStatusOnQueue)
        Self.messagesControllerQueue.setIdleCallback { quiescence in
            do {
                try observe(quiescence)
            } catch {
                platformLog.error("failed to observe activity: \(error)")
            }
        }

        let requestID = UUID()
        threadObserveRequestToken.withLock { $0 = requestID }

        try await Self.onMessagesControllerQueue {
            // if another watchThreadActivity request has been enqueued
            // after our current one (but before this block began executing),
            // then this check will fail and prevent the current block from
            // unnecessarily running
            guard self.threadObserveRequestToken.read() == requestID else { return }

            try observe(.began)
        }
    }

    @discardableResult
    private func performControllerOperation<AttemptContext>(
        name: String,
        retries: Int,
        prepareAttempt: @escaping @Sendable () async throws -> AttemptContext,
        _ action: @escaping @Sendable (MessagesController) throws -> Void,
        afterAttempt: (@Sendable (AttemptContext) async throws -> Void)? = nil
    ) async throws -> AttemptContext {
        try await retry(retries: retries) { attempt in
            let context = try await prepareAttempt()
            let controller = try await getMessagesController(forceInvalidate: attempt > 0)
            try await Self.onMessagesControllerQueue {
                try action(controller)
            }
            try await afterAttempt?(context)
            return context
        } onError: { _, retriesLeft, error in
            platformLog.error("\(name) failed, retries left: \(retriesLeft): \(error)")
            try? self.reportMessageToSentry("imessage \(name) failed: \(error)")
        }
    }

    private func retryReactionOperation(threadID: String, messageID: String, reaction: String, on: Bool) async throws {
        try await performControllerOperation(
            name: "setReaction",
            retries: 2,
            prepareAttempt: { try await self.lastMessageRowID() }
        ) { controller in
            try controller.setReaction(threadID: threadID, messageID: messageID, reactionName: reaction, on: on)
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
        return try await DetachedWork.run {
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
        let controller = try await getMessagesController()
        let address = threadIDToAddress(threadID)
        let sentThreadIsValid = try await Self.onMessagesControllerQueue {
            sentThreadIDs.allSatisfy { sentThreadID in
                sentThreadID == threadID || (
                    sentThreadID != nil
                        && controller.isSameContact(address, threadIDToAddress(sentThreadID!))
                )
            }
        }

        guard sentThreadIsValid else {
            platformLog.error("imsg: imessage potentially sent messages to invalid thread")
            return "true"
        }

        let messages = try await sentMessages(sentMessageIDs)
        validateLinkedMessageIDs(messages, expectedLinkedMessageID: expectedLinkedMessageID)
        return try encodeJSON(messages)
    }

    private func waitForSentMessageIDs(
        since lastRowID: Int,
        text: String?,
        timeout: TimeInterval
    ) async throws -> [(rowID: Int, guid: String)] {
        let database = database
        return try await DetachedWork.run {
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
        return try await DetachedWork.run {
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
        try await runDBQuery { db, currentUser, accountID in
            var messages = [JSONObject]()
            for sentMessageID in sentMessageIDs {
                guard let message = try Self.messageObject(
                    db: db,
                    threadID: nil,
                    messageID: sentMessageID.guid,
                    currentUserID: currentUser.id,
                    accountID: accountID
                ) else {
                    continue
                }
                messages.append(message.jsonObject)
            }
            return messages
        }
    }

    private func validateLinkedMessageIDs(_ messages: [JSONObject], expectedLinkedMessageID: String?) {
        for message in messages where message.bool("isHidden") != true {
            let actual = message.string("linkedMessageID")
            guard expectedLinkedMessageID != actual else {
                continue
            }
            platformLog.error("imsg: sent message with incorrect quoted message, intended: \(String(describing: expectedLinkedMessageID)), actual: \(String(describing: actual))")
            try? reportMessageToSentry("imessage sent message with incorrect quoted message, intended=\(expectedLinkedMessageID != nil) actual=\(actual != nil)")
        }
    }

    private func reportMessageToSentry(_ message: String) throws {
        try runtime.reportMessageToSentry(message)
    }

    private static func onMessagesControllerQueue<T>(
        _ action: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            messagesControllerQueue.async {
                continuation.resume(with: Result { try action() })
            }
        }
    }

    private func makeMessagesController() async throws -> MessagesController {
        return try await Self.onMessagesControllerQueue {
            try MessagesController(reportToSentry: { [runtime = self.runtime] txt in
                platformLog.error("<!> report to sentry: \(txt)")
                try? runtime.reportMessageToSentry(txt)
            })
        }
    }

    nonisolated static func getThreads(
        db: IMDatabase,
        folderName: String,
        cursor: String?,
        direction: String?,
        currentUser: CurrentUser,
        accountID: String
    ) throws -> PlatformAPIPage<PlatformAPIThread> {
        guard folderName == "normal" else {
            return PlatformAPIPage(items: [], hasMore: false, oldestCursor: "0")
        }

        let pageDirection = direction.flatMap(MappedThreadPageDirection.init(rawValue:))
        let chatRows = try db.mappedThreadRows(cursor: cursor, direction: pageDirection)
        let chatRowIDs = chatRows.map(\.rowID)
        let latestMessageRowsByChatGUID = try latestThreadMessageRowsByChatGUID(db: db, chatRows: chatRows)
        let context = ThreadMapper.Context(
            handleRowsByChatRowID: try db.mappedThreadParticipantRows(chatRowIDs: chatRowIDs),
            latestMessagesByChatGUID: try latestThreadMessagesByChatGUID(
                db: db,
                latestMessageRowsByChatGUID,
                currentUserID: currentUser.id,
                accountID: accountID
            ),
            unreadCounts: try db.mappedUnreadCounts(chatRowIDs: chatRowIDs),
            dndState: permanentDNDThreadIDs(),
            currentUser: currentUser,
            accountID: accountID
        )
        let threads = try chatRows.map { try PlatformAPIThread(jsonObject: ThreadMapper.mapAndHashThread($0, context: context)) }
        // TODO: Change the API design so getThreads is side-effect free and
        // the polling bootstrap is triggered by an explicit lifecycle call.
        if cursor == nil, let pollingCursor = ThreadMapper.pollingCursor(from: Array(latestMessageRowsByChatGUID.values)) {
            PollingLifecycle.shared.startBootstrapIfNecessary(
                lastRowID: pollingCursor.maxRowID,
                lastDateRead: Date(nanosecondsSinceReferenceDate: pollingCursor.maxDateReadNanoseconds)
            )
        }
        return PlatformAPIPage(
            items: threads,
            hasMore: chatRows.count == mappedThreadsLimit,
            oldestCursor: chatRows.last?.msgDate.map(String.init)
        )
    }

    nonisolated static func getThread(
        db: IMDatabase,
        threadID publicThreadID: String,
        currentUser: CurrentUser,
        accountID: String
    ) throws -> PlatformAPIThread? {
        let threadID = try originalThreadID(db: db, publicThreadID)
        guard let chatRow = try db.mappedThreadRow(guid: threadID) else {
            return nil
        }
        let chatRowIDs = [chatRow.rowID]
        let latestMessageRowsByChatGUID = try latestThreadMessageRowsByChatGUID(db: db, chatRows: [chatRow])
        let context = ThreadMapper.Context(
            handleRowsByChatRowID: try db.mappedThreadParticipantRows(chatRowIDs: chatRowIDs),
            latestMessagesByChatGUID: try latestThreadMessagesByChatGUID(
                db: db,
                latestMessageRowsByChatGUID,
                currentUserID: currentUser.id,
                accountID: accountID
            ),
            unreadCounts: try db.mappedUnreadCounts(chatRowIDs: chatRowIDs),
            dndState: permanentDNDThreadIDs(),
            currentUser: currentUser,
            accountID: accountID
        )
        return try PlatformAPIThread(jsonObject: ThreadMapper.mapAndHashThread(chatRow, context: context))
    }

    nonisolated static func getMessages(
        db: IMDatabase,
        threadID publicThreadID: String,
        cursor: String?,
        direction: String?,
        currentUserID: String,
        accountID: String,
        limit: Int? = nil
    ) throws -> PlatformAPIPage<PlatformAPIMessage> {
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
        return PlatformAPIPage(
            items: messages.map(PlatformAPIMessage.init(jsonObject:)),
            hasMore: msgRows.count == effectiveLimit
        )
    }

    nonisolated static func getMessage(
        db: IMDatabase,
        threadID publicThreadID: String,
        messageID: String,
        currentUserID: String,
        accountID: String
    ) throws -> PlatformAPIMessage? {
        try messageObject(
            db: db,
            threadID: publicThreadID,
            messageID: messageID,
            currentUserID: currentUserID,
            accountID: accountID
        )
    }

    nonisolated static func messageObject(
        db: IMDatabase,
        threadID publicThreadID: String?,
        messageID: String,
        currentUserID: String,
        accountID: String
    ) throws -> PlatformAPIMessage? {
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
        return messages.first(where: { ($0["id"] as? String) == messageID }).map(PlatformAPIMessage.init(jsonObject:))
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
    ) throws -> PlatformAPIPage<PlatformAPIMessage> {
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
            return PlatformAPIPage(items: [], hasMore: false, oldestCursor: "")
        }

        let msgRows = try db.mappedMessageRows(rowIDs: matchingRowIDs)
        let attachmentRows = decorateAttachments(try db.mappedAttachmentRows(messageRowIDs: msgRows.map(\.rowID)))
        let messageGUIDs = msgRows.map(\.guid)
        let reactionRows = try threadID.map { try db.mappedReactionRows(messageGUIDs: messageGUIDs, chatGUID: $0) } ?? []
        let messages = try mapAndHashMessages(
            msgRows: msgRows,
            attachmentRows: attachmentRows,
            reactionRows: reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
        return PlatformAPIPage(
            items: messages.map(PlatformAPIMessage.init(jsonObject:)),
            hasMore: matchingRowIDs.count == effectiveLimit,
            oldestCursor: msgRows.first?.date.map(String.init) ?? ""
        )
    }
}

extension PlatformAPI {
    private struct MessagePayloadRows {
        var attachmentRows: [MappedAttachmentRow]
        var reactionRows: [MappedReactionMessageRow]
    }

    nonisolated static func latestThreadMessageRowsByChatGUID(db: IMDatabase, chatRows: [MappedChatRow]) throws -> [String: MappedMessageRow] {
        try db.mappedLatestMessageRows(chatRowIDs: chatRows.map(\.rowID))
    }

    nonisolated static func latestThreadMessagesByChatGUID(
        db: IMDatabase,
        _ latestMessageRowsByChatGUID: [String: MappedMessageRow],
        currentUserID: String,
        accountID: String
    ) throws -> [String: [JSONObject]] {
        let msgRows = Array(latestMessageRowsByChatGUID.values)
        let payloadRows = try messagePayloadRows(db: db, msgRows: msgRows, threadID: "")
        let attachmentRowsByMessageID = Dictionary(grouping: payloadRows.attachmentRows, by: \.msgRowID)
        let reactionRowsByMessageGUID = Dictionary(grouping: payloadRows.reactionRows, by: { reactionMessageGUID($0.associatedMessageGUID) })

        var latestMessagesByChatGUID = [String: [JSONObject]]()
        for (guid, msgRow) in latestMessageRowsByChatGUID {
            latestMessagesByChatGUID[guid] = try mapAndHashMessage(
                msgRow: msgRow,
                attachmentRows: attachmentRowsByMessageID[msgRow.rowID] ?? [],
                reactionRows: reactionRowsByMessageGUID[msgRow.guid] ?? [],
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

    nonisolated private static func temporaryAttachmentDirectoryURL() -> URL {
        MessagesPaths.temporaryPlatformAttachmentDirectory
    }

    nonisolated private static func writeTemporaryAttachmentFile(data: Data, fileName: String?) throws -> String {
        let directoryURL = temporaryAttachmentDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let effectiveFileName: String
        if let fileName, !fileName.isEmpty {
            effectiveFileName = fileName
        } else {
            effectiveFileName = UUID().uuidString
        }
        let fileURL = directoryURL.appendingPathComponent(effectiveFileName)
        try data.write(to: fileURL)
        return fileURL.path
    }

    nonisolated private static func cleanupTemporaryAttachmentDirectory() {
        try? FileManager.default.removeItem(at: temporaryAttachmentDirectoryURL())
    }

    nonisolated private static func messagePayloadRows(
        db: IMDatabase,
        msgRows: [MappedMessageRow],
        threadID: String
    ) throws -> MessagePayloadRows {
        guard !msgRows.isEmpty else {
            return MessagePayloadRows(attachmentRows: [], reactionRows: [])
        }

        let msgRowIDs = msgRows.map(\.rowID)
        let msgGUIDs = msgRows.map(\.guid)
        let chatRowIDs = Array(Set(msgRows.compactMap(\.chatRowID)))
        let reactionRows: [MappedReactionMessageRow]
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
        msgRows: [MappedMessageRow],
        attachmentRows: [MappedAttachmentRow],
        reactionRows: [MappedReactionMessageRow],
        currentUserID: String,
        accountID: String
    ) throws -> [JSONObject] {
        guard !msgRows.isEmpty else {
            return []
        }

        let attachmentRowsByMessageID = Dictionary(grouping: attachmentRows, by: \.msgRowID)
        let reactionRowsByMessageGUID = Dictionary(grouping: reactionRows, by: { reactionMessageGUID($0.associatedMessageGUID) })

        return try msgRows.flatMap { msgRow -> [JSONObject] in
            try mapAndHashMessage(
                msgRow: msgRow,
                attachmentRows: attachmentRowsByMessageID[msgRow.rowID] ?? [],
                reactionRows: reactionRowsByMessageGUID[msgRow.guid] ?? [],
                currentUserID: currentUserID,
                accountID: accountID
            )
        }
    }

    nonisolated static func mapAndHashMessage(
        msgRow: MappedMessageRow,
        attachmentRows: [MappedAttachmentRow],
        reactionRows: [MappedReactionMessageRow],
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
            msgRow: msgRow.object,
            attachmentRows: attachmentRows.objects,
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
        guard !Preferences.stripInternalFields else {
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

    nonisolated static func decorateAttachments(_ attachmentRows: [MappedAttachmentRow]) -> [MappedAttachmentRow] {
        attachmentRows.map { attachmentRow in
            let rawFilePath = attachmentRow.filename
            let filePath = rawFilePath.map(replaceTilde)
            let transferName = attachmentRow.transferName
            let base = filePath.map { ($0 as NSString).lastPathComponent } ?? transferName ?? ""
            let ext = filePath.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
            var size: [String: Int]?

            if let filePath,
               imageExtensions.contains(ext) || ext == "pluginpayloadattachment",
               let metadataSize = ImageMetadataReader.cachedRead(from: filePath) {
                size = [
                    "width": metadataSize.width,
                    "height": metadataSize.height,
                ]
            }
            return MappedAttachmentRow(
                msgRowID: attachmentRow.msgRowID,
                filename: attachmentRow.filename,
                transferName: attachmentRow.transferName,
                totalBytes: attachmentRow.totalBytes,
                isSticker: attachmentRow.isSticker,
                attachmentID: attachmentRow.attachmentID,
                transferState: attachmentRow.transferState,
                ext: ext,
                fileName: transferName?.isEmpty == false ? transferName! : base,
                filePath: filePath,
                size: size
            )
        }
    }

    nonisolated static func reactionMessageGUID(_ associatedMessageGUID: String) -> String {
        let range = NSRange(associatedMessageGUID.startIndex ..< associatedMessageGUID.endIndex, in: associatedMessageGUID)
        guard let match = assocMsgGUIDPrefixRegex.firstMatch(in: associatedMessageGUID, range: range),
              let upper = Range(match.range, in: associatedMessageGUID)?.upperBound else {
            return associatedMessageGUID
        }
        return String(associatedMessageGUID[upper...])
    }

    nonisolated private static func getAsset(db database: PlatformAPIDatabase, pathHex: String, methodName: String) throws -> AssetResult {
        switch pathHex {
        case "hw":
            let uuid = methodName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? methodName
            let prefix = "hw_\(uuid)_"
            for _ in 0 ..< 10 {
                let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: MessagesPaths.temporaryMobileSMSPath)) ?? []
                if let fileName = fileNames.first(where: { $0.hasPrefix(prefix) }) {
                    return .url(fileURLString(MessagesPaths.temporaryMobileSMSDirectory.appendingPathComponent(fileName).path))
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw ErrorMessage("Couldn't fetch handwriting asset")

        case "dt":
            let uuid = methodName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? methodName
            let filePath = MessagesPaths.temporaryMobileSMSDirectory.appendingPathComponent("\(uuid).mov").path
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
}
