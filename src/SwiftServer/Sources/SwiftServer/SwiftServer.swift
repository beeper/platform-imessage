import NodeAPI
import Foundation
import WindowControl
import SwiftServerFoundation
import Logging

private let sentryLog = Logger(swiftServerLabel: "sentry")
private let log = Logger(swiftServerLabel: "swift-server")
private let queueLog = Logger(swiftServerLabel: "queue")

let messagesDir = try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    .appendingPathComponent("Messages", isDirectory: true)

// not depending on swift-atomics for now
private let queueCounter = Protected<Int>(0)

@available(macOS 11, *)
@NodeActor @NodeClass final class MessagesControllerWrapper {
    static let name = "MessagesController"

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

#if DEBUG
@available(macOS 11, *)
extension MessagesControllerWrapper {
    @NodeMethod func _getMainWindow() {
        do {
            let window = try self.controller.elements.mainWindow
            Log.default.debug("@@@ [DEBUG] was able to fetch main window: \(window)")
        } catch {
            Log.default.error("@@@ [DEBUG] ❌ COULDN'T get main window! \(error)")
        }
    }
}
#endif

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

    Task {
        // we trim as we log (within reason), but always try to do it on startup
        try? await LogFileCoordinator.shared?.tryTrimming()
    }

    let greeting = "howdy from SwiftServer!"
    if let system = System() {
        log.info("\(greeting) (\(system.os) \(system.kernelVersion) \(system.architecture), \(system.osVersion))")
    } else {
        log.info("\(greeting)")
    }

    Defaults.registerDefaults()

    Task { @MainActor in
        guard Defaults.swiftServer.bool(forKey: DefaultsKeys.settingsMenuItemInjection) else { return }

        if #available(macOS 13, *) {
            log.debug("trying to inject settings menu item whenever possible")
            MenuMaintainer.shared.add(maintaining: SettingsView.menuItem)
        } else {
            log.debug("couldn't inject settings menu item, macOS 13 or later is needed")
        }
    }

    // strongly retained by askForMessagesDirAccess, deinit called on exit
    let accessManager = MessagesAccessManager()
    var pollingTask: Task<Void, Never>?

    var dict: [String: NodePropertyConvertible] = try [
        "hashers": [
            "thread": try Hasher.thread.nodeValue(),
            "participant": try Hasher.participant.nodeValue(),
        ].nodeValue(),

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

        "cancelPollingIfNecessary": NodeFunction {
            defer { pollingTask = nil }
            if let pollingTask {
                log.info("was asked to cancel polling task, doing so")
                pollingTask.cancel()
            } else {
                log.warning("was asked to cancel polling task, but there isn't one; disregarding")
            }
            return
        },

        "startPolling": NodeFunction { (onEvent: NodeFunction, lastRowIDBig: NodeBigInt, lastDateReadNanosecondsBig: NodeBigInt) in
            if let task = pollingTask {
                log.warning("was asked to start polling, but there was already a poller alive; canceling it before proceeding")
                task.cancel()
                pollingTask = nil
            }

            let lastRowID = Int(try lastRowIDBig.signed().value)
            let lastDateRead = Date(nanosecondsSinceReferenceDate: Int(try lastDateReadNanosecondsBig.signed().value))
            log.debug("was asked to start polling (last row id: \(lastRowID), last date read: \(lastDateRead))")

            let poller = try Poller(serverEventSender: { events in
                var values = [any NodeValueConvertible]()
                // this probably isn't worth doing in parallel
                for event in events {
                    values.append(try await event.nodeValue())
                }
#if DEBUG
                log.debug("handing over \(values.count) value(s) to the event callback")
#endif
                try await onEvent.call([values])
            }, initialUpdatesCursor: Poller.MessageUpdatesCursor(lastRowID: lastRowID, lastDateRead: lastDateRead))

            pollingTask = Task {
                log.debug("going to poll forever")
                do {
                    try await poller.pollForever()
                } catch {
                    log.error("poller died: \(String(reflecting: error))")
                }
            }

            return // needed to resolve a compile-time type ambiguity apparently
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
        },

        "revealSettings": NodeFunction {
            log.debug("told to reveal settings window")
            Task { @MainActor in
                guard #available(macOS 13, *) else {
                    log.error("can't reveal settings on macOS <13")
                    return
                }
                guard let window = SettingsWindowController.shared.window else {
                    log.error("can't reveal settings, no window?")
                    return
                }
                log.debug("revealing settings window")
                window.makeKeyAndOrderFront(nil)
            }
            // needed or else we get a type ambiguity error?
            return undefined
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
