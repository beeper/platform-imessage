import NodeAPI
import Foundation
import WindowControl
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "messages-controller-wrapper")
private let queueLog = Logger(swiftServerLabel: "queue")
private let sentryLog = Logger(swiftServerLabel: "sentry")

@available(macOS 11, *)
@NodeActor @NodeClass final class MessagesControllerWrapper {
    static let name = "MessagesController"
    
    // not depending on swift-atomics for now
    private static let queueCounter = Protected<Int>(0)

    static let queue = PassivelyAwareDispatchQueue(label: "messages-controller-wrapper-queue", idleDelay: 1)

    private static func returnAsync(
        on jsQueue: NodeAsyncQueue,
        function: StaticString = #function,
        _ action: @escaping () throws -> NodeValueConvertible
    ) throws -> NodePromise {
        let id = queueCounter.withLock {
            let current = $0
            $0 += 1
            return current
        }

        queueLog.debug("\(function)#\(id): materializing promise")
        return try NodePromise { deferred in
            queue.async {
                let result = Result { try action() }
                try? jsQueue.run {
                    let settleResult = switch result {
                    case .success: "resolved"
                    case .failure: "rejected"
                    }
                    queueLog.debug("\(function)#\(id): \(settleResult)")
                    try deferred(result)
                }
            }
        }
    }

    private func returnAsync(
        function: StaticString = #function,
        _ action: @escaping () throws -> NodeValueConvertible
    ) throws -> NodePromise {
        try Self.returnAsync(on: swiftJSQueue, function: function, action)
    }

    private func performAsync(
        function: StaticString = #function,
        _ action: @escaping () throws -> Void
    ) throws -> NodePromise {
        try returnAsync(function: function) {
            try action()
            return undefined
        }
    }

    private func returnAsync(
        _ action: @escaping () async throws -> NodeValueConvertible
    ) throws -> NodePromise {
        try NodePromise { try await action() }
    }

    private func performAsync(
        _ action: @escaping () async throws -> Void
    ) throws -> NodePromise {
        try returnAsync {
            try await action()
            return undefined
        }
    }

    @NodeMethod static func create() throws -> NodeValueConvertible {
        addBreadcrumb("Creating async queue")
        let q = try NodeAsyncQueue(label: "create-messages-controller")
        addBreadcrumb("Opening async context")
        return try returnAsync(on: q) {
            let controller = try MessagesController(reportToSentry: { txt in
                sentryLog.error("<!> report to sentry: \(txt)")
                try? q.run {
                    try Node.texts.Sentry.captureMessage(txt)
                }
            })
            return NodeDeferredValue {
                addBreadcrumb("NodeDeferred.init")
                return try MessagesControllerWrapper(controller: controller).wrapped()
            }
        }
    }

    private static func addBreadcrumb(_ message: String) {
        _ = try? Node.texts.Sentry.addBreadcrumb([
            "category": "swiftserver",
            "level": "info",
            "message": message
        ])
        sentryLog.info("[breadcrumb] \(message)")
    }

    private var threadObserveRequestToken: UUID?
    private var hasBeenDisposed = false
    private let threadObserveRequestTokenLock = UnfairLock()

    private let swiftJSQueue: NodeAsyncQueue
    private let watchCBQueue: NodeAsyncQueue

    let controller: MessagesController
    let hook: AsyncCleanupHook
    // must be called on JS queue
    init(controller: MessagesController) throws {
        Log.default.notice("[MessagesControllerWrapper] init")
        self.controller = controller
        self.swiftJSQueue = try NodeAsyncQueue(label: "messages-controller-async")
        self.watchCBQueue = try NodeAsyncQueue(label: "watch-imessage-callback")
        hook = try NodeEnvironment.current.addCleanupHook { completion in
            Log.default.notice("[MessagesControllerWrapper] running dispose inside cleanup hook")
            controller.dispose()
            completion()
        }
    }

    @NodeMethod func isValid() throws -> NodeValueConvertible {
        try returnAsync { () async in
            let result = self.controller.isValid
            log.debug("isValid called (async path), returning \(result)")
            return result
        }
    }

    @NodeMethod func toggleThreadRead(threadID: String, read: Bool) throws -> NodeValueConvertible {
        try performAsync { try self.controller.toggleThreadRead(threadID: threadID, read: read) }
    }

    @NodeMethod func muteThread(threadID: String, muted: Bool) throws -> NodeValueConvertible {
        try performAsync { try self.controller.muteThread(threadID: threadID, muted: muted) }
    }

    @NodeMethod func deleteThread(threadID: String) throws -> NodeValueConvertible {
        try performAsync { try self.controller.deleteThread(threadID: threadID) }
    }

    @NodeMethod func sendTypingStatus(threadID: String, isTyping: Bool) throws -> NodeValueConvertible {
        try performAsync { try self.controller.sendTypingStatus(threadID: threadID, isTyping: isTyping) }
    }

    @NodeMethod func notifyAnyway(threadID: String) throws -> NodeValueConvertible {
        try performAsync { try self.controller.notifyAnyway(threadID: threadID) }
    }

    @NodeMethod func watchThreadActivity(_ args: NodeArguments) throws -> NodeValueConvertible {
        guard Defaults.swiftServer.bool(forKey: DefaultsKeys.watchThreadActivity) else {
            return undefined
        }

        let controllerArgs: (String, ([ActivityStatus]) -> Void)?

        // reset the idle callback in case we fail and bail out
        Self.queue.setIdleCallback(nil)

        guard args.count == 2,
              let threadID = try args[0].as(String.self),
              let sendStatus = try args[1].as(NodeFunction.self)
        else {
            log.error("invalid args passed to watchThreadActivity")
            return undefined
        }

        // only watch thread activity for iMessage chats
        // TODO: implement this for groups
        if !threadID.hasPrefix("iMessage;-;") {
            guard threadID.hasPrefix("any;-;") else {
            // only bother checking the database if the GUID can't tell us what service the chat is for
            // (can happen seemingly since macOS 26, which can use "any" as a universal GUID prefix)
#if DEBUG
            log.debug("chat isn't an iMessage 1:1 DM, not watching for activity")
#endif
                return undefined
            }

            let chat = try self.controller.db.chat(withGUID: threadID)
            guard let chat else {
                log.error("watchThreadActivity: couldn't locate the chat to watch in the database")
                return undefined
            }

            guard chat.serviceName == .imessage else {
#if DEBUG
            log.debug("chat definitely isn't an iMessage 1:1 DM, not watching for activity")
#endif
                return undefined
            }
        }

        let sendStatusOnQueue = { (statuses: [ActivityStatus]) in
            try? self.watchCBQueue.run {
                try sendStatus(statuses.map(\.rawValue))
            }
            return
        }

        // it's okay that we aren't using `performAsync`/`returnAsync` here -
        // the idle callback is itself submitted onto the queue, so everything's
        // still serial
        let observe = try controller.idleCallback(observingThreadID: threadID, statusSender: sendStatusOnQueue)
        Self.queue.setIdleCallback { quiescence in
            do {
                try observe(quiescence)
            } catch {
                log.error("failed to observe activity: \(error)")
            }
        }

        return undefined
    }

    @NodeMethod func setReaction(threadID: String, messageCellJSON: String, reactionName: String, on: Bool) throws -> NodeValueConvertible {
        guard let messageCell = (try messageCellJSON.data(using: .utf8).flatMap { try JSONDecoder().decode(MessageCell.self, from: $0) }) else {
            throw ErrorMessage("Invalid messageCellJSON arg")
        }

        let reaction = if let reaction = Reaction(platformSDKReactionKey: reactionName) {
            // try the "legacy" reactions first (keyed by `supported` in platform info)
            reaction
        } else {
            // assume an emoji itself was passed (beeper desktop)
            reactionName.withoutSkinToneModifiers.first.flatMap(Reaction.init(emoji:))
        }

        guard let reaction else {
            log.error("couldn't create reaction from provided name: \(reactionName)")
            throw ErrorMessage("Couldn't create reaction from \"\(reactionName)\"")
        }
        return try performAsync { [self] in
            try await controller.setReaction(threadID: threadID, messageCell: messageCell, reaction: reaction, on: on)
        }
    }

    // @available(macOS 13, *)
    @NodeMethod func undoSend(threadID: String, messageCellJSON: String) throws -> NodeValueConvertible {
        guard let messageCell = (try messageCellJSON.data(using: .utf8).flatMap { try JSONDecoder().decode(MessageCell.self, from: $0) }) else {
            throw ErrorMessage("Invalid messageCellJSON arg")
        }
        return try performAsync { [self] in
            try controller.undoSend(threadID: threadID, messageCell: messageCell)
        }
    }

    @NodeMethod func editMessage(threadID: String, messageCellJSON: String, newText: String) throws -> NodeValueConvertible {
        guard let messageCell = (try messageCellJSON.data(using: .utf8).flatMap { try JSONDecoder().decode(MessageCell.self, from: $0) }) else {
            throw ErrorMessage("Invalid messageCellJSON arg")
        }
        return try performAsync { [self] in
            try controller.editMessage(threadID: threadID, messageCell: messageCell, newText: newText)
        }
    }

    @NodeMethod func createThread(_ args: NodeArguments) throws -> NodeValueConvertible {
        guard args.count == 2,
              let addresses = try args[0].as([String].self),
              let message = try args[1].as(String.self) else {
            throw ErrorMessage("Bad MessagesController call: \(#function)")
        }
        return try performAsync {
            try self.controller.sendMessage(threadID: nil, addresses: addresses, text: message, filePath: nil, quotedMessage: nil)
        }
    }

    @NodeMethod func sendMessage(threadID: String, text: String?, filePath: String?, quotedMessageCellJSON: String?) throws -> NodeValueConvertible {
        let quotedMessage = try quotedMessageCellJSON?.data(using: .utf8).flatMap { try JSONDecoder().decode(MessageCell.self, from: $0) }
        return try performAsync { try self.controller.sendMessage(threadID: threadID, addresses: nil, text: text, filePath: filePath, quotedMessage: quotedMessage) }
    }

    @NodeMethod func isSameContact(_ a: String?, _ b: String?) -> Bool {
        return self.controller.isSameContact(a, b)
    }

    @NodeMethod func dispose() throws {
        guard !hasBeenDisposed else {
            // NOTE(skip): Guard against `dispose` being called more than once, which triggers a UAF via napi_remove_env_cleanup_hook. (DESK-7237)
            Log.default.warning("[MessagesControllerWrapper] dispose called when already disposed, ignoring")
            return
        }
        hasBeenDisposed = true

        Log.default.notice("[MessagesControllerWrapper] disposing")
        Self.queue.queue.sync { controller.dispose() }
        try NodeEnvironment.current.removeCleanupHook(hook)
    }
}
