import NodeAPI
import Foundation
import WindowControl
import SwiftServerFoundation
import Logging

private let sentryLog = Logger(swiftServerLabel: "sentry")

let messagesDir = try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    .appendingPathComponent("Messages", isDirectory: true)

@available(macOS 11, *)
@NodeActor @NodeClass final class MessagesControllerWrapper {
    static let name = "MessagesController"

    private static let queue = DispatchQueue(label: "messages-controller-wrapper-queue")

    private static func returnAsync(
        on jsQueue: NodeAsyncQueue,
        function: StaticString = #function,
        _ action: @escaping () throws -> NodeValueConvertible
    ) throws -> NodePromise {
        addBreadcrumb("Calling returnAsync from \(function)")
        return try NodePromise { deferred in
            queue.async {
                let result = Result { try action() }
                try? jsQueue.run {
                    addBreadcrumb("Resolving returnAsync from \(function)")
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
    private let threadObserveRequestTokenLock = UnfairLock()

    private let swiftJSQueue: NodeAsyncQueue
    private let watchCBQueue: NodeAsyncQueue

    let controller: MessagesController
    let hook: AsyncCleanupHook
    // must be called on JS queue
    init(controller: MessagesController) throws {
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
        try returnAsync { self.controller.isValid }
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
        let controllerArgs: (String, ([MessagesController.ActivityStatus]) -> Void)?
        if try args.count == 1 && args[0].as(NodeNull.self) != nil {
            controllerArgs = nil
        } else if args.count == 2,
                  let threadID = try args[0].as(String.self),
                  let fn = try args[1].as(NodeFunction.self) {
            controllerArgs = (threadID, { status in
                try? self.watchCBQueue.run { try fn(status.map { $0.rawValue }) }
            })
        } else {
            print("warning: Invalid args to watchThreadActivity")
            controllerArgs = nil
        }
        let req = UUID()
        do {
            threadObserveRequestTokenLock.lock()
            defer { threadObserveRequestTokenLock.unlock() }
            threadObserveRequestToken = req
        }
        return try performAsync { [self] in
            do {
                threadObserveRequestTokenLock.lock()
                defer { threadObserveRequestTokenLock.unlock() }
                // if another watchThreadActivity request has been enqueued
                // after our current one (but before this performAsync block
                // began executing), then this check will fail and therefore
                // prevent the current block from unnecessarily running
                guard threadObserveRequestToken == req else { return }
            }
            if let (threadID, callback) = controllerArgs {
                try controller.observe(threadID: threadID, callback: callback)
            } else {
                try controller.removeObserver()
            }
        }
    }

    @NodeMethod func setReaction(threadID: String, messageCellJSON: String, reactionName: String, on: Bool) throws -> NodeValueConvertible {
        guard let messageCell = (try messageCellJSON.data(using: .utf8).flatMap { try JSONDecoder().decode(MessageCell.self, from: $0) }) else {
            throw ErrorMessage("Invalid messageCellJSON arg")
        }
        guard let reaction = MessagesController.Reaction(rawValue: reactionName) else {
            throw ErrorMessage("Invalid reaction: \(reactionName)")
        }
        return try performAsync { [self] in
            try controller.setReaction(threadID: threadID, messageCell: messageCell, reaction: reaction, on: on)
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
        Self.queue.sync { controller.dispose() }
        try NodeEnvironment.current.removeCleanupHook(hook)
    }
}

@available(macOS 10.15, *)
enum SysPrefsOnboarding {
    static var onboardingManager: OnboardingManager? = nil

    static func start() {
        guard onboardingManager == nil else { return }
        let onboardingManager = OnboardingManager()
        self.onboardingManager = onboardingManager
        onboardingManager.createWindow()
    }

    static func stop() {
        onboardingManager?.closeWindow()
        onboardingManager = nil
    }
}

enum Preferences {
    static var isLoggingEnabled = false
    static var isPHTEnabled = false
    static var enabledExperiments = ""
}

#NodeModule {
    // this needs to be bootstrapped as early as possible, because it needs to
    // be ready by the first `debugLog` call, or else subsequent calls to that
    // function are dropped
    LoggingSystem.bootstrap({ identifier in
        SwiftServerLogHandler(identifier: identifier)
    })

    // strongly retained by askForMessagesDirAccess, deinit called on exit
    let accessManager = MessagesAccessManager()
    var dict: [String: NodePropertyConvertible] = try [
        "appleInterfaceStyle": NodeProperty { _ in
            UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        },

        "isMessagesAppInDock": NodeProperty { _ in
            Defaults.isAppInDock(bundleID: messagesBundleID)
        },

        "isNotificationsEnabledForMessages": NodeProperty { _ in
            Defaults.isNotificationsEnabledForApp(bundleID: messagesBundleID)
        },

        "enabledExperiments": NodeProperty { _ in
            Preferences.enabledExperiments
        } set: { args in
            Preferences.enabledExperiments = try args.first?.as(String.self) ?? ""
        },

        "isLoggingEnabled": NodeProperty { _ in
            Preferences.isLoggingEnabled
        } set: { args in
            Preferences.isLoggingEnabled = try args.first?.as(Bool.self) ?? false
        },

        "isPHTEnabled": NodeProperty { _ in
            Preferences.isPHTEnabled
        } set: { args in
            Preferences.isPHTEnabled = try args.first?.as(Bool.self) ?? false
        },

        "askForMessagesDirAccess": NodeFunction {
            try await accessManager.requestAccess()
        },

        "askForAutomationAccess": NodeFunction {
            let queue = try NodeAsyncQueue(label: "automation-access-callback")
            return try NodePromise { deferred in
                DispatchQueue.main.async {
                    let result = Result<NodeValueConvertible, Error> {
                        try OSA.promptAutomationAccess()
                        return undefined
                    }
                    try? queue.run {
                        try deferred(result)
                    }
                }
            }
        },

        "decodeAttributedString": NodeFunction { (data: Data) in
            guard let decoded = try? AttributedStringDecoder.decodeAttributedString(from: data) else {
                return undefined
            }
            return decoded.map { [
                "from": Double($0.scalarRange.lowerBound),
                "to": Double($0.scalarRange.upperBound),
                "text": "\($0.text)",
                "attributes": $0.attributes.mapValues { "\($0)" }
            ] }
        },

        "confirmUNCPrompt": NodeFunction {
            let queue = try NodeAsyncQueue(label: "prompt-automation-callback")
            return try NodePromise { deferred in
                // we don't use DispatchQueue.main to prevent freezing the UI
                DispatchQueue.global(qos: .background).async {
                    let result = Result<NodeValueConvertible, Error> {
                        try PromptAutomation.confirmUNCPrompt()
                        return undefined
                    }
                    try? queue.run {
                        try deferred(result)
                    }
                }
            }
        },

        "disableNotificationsForApp": NodeFunction { (appName: String) in
            let queue = try NodeAsyncQueue(label: "prompt-automation-callback")
            return try NodePromise { deferred in
                // we don't use DispatchQueue.main to prevent freezing the UI
                DispatchQueue.global(qos: .background).async {
                    let result = Result<NodeValueConvertible, Error> {
                        try PromptAutomation.disableNotificationsForApp(named: appName)
                    }

                    try? queue.run {
                        try deferred(result)
                    }
                }
            }
        },

        "removeMessagesFromDock": NodeFunction {
            Defaults.removeAppFromDock(bundleID: messagesBundleID)
        },

        "killDock": NodeFunction {
            Dock.getApp()?.terminate()
        },

        "disableSoundEffects": NodeFunction {
            Defaults.playSoundEffects = false
        },

        "getDNDList": NodeFunction {
            guard let dict = Defaults.getDNDList() else {
                return undefined
            }
            let list = dict.compactMap { $0.value == Int(Date.distantFuture.timeIntervalSince1970) ? $0.key : nil }
            return list as [NodeValueConvertible]
        }
    ]

    if #available(macOS 10.15, *) {
        dict["startSysPrefsOnboarding"] = try NodeFunction {
            SysPrefsOnboarding.start()
        }
        dict["stopSysPrefsOnboarding"] = try NodeFunction {
            SysPrefsOnboarding.stop()
        }
    }
    if #available(macOS 11, *) {
        dict["MessagesController"] = try MessagesControllerWrapper.constructor()
    }

    return dict
}
