import NodeAPI
import Foundation

final class MessagesControllerWrapper: NodeClass {
    static let properties: NodeClassPropertyList = [
        "create": NodeMethod(attributes: .static, create),
        "isValid": NodeMethod(isValid),
        "createThread": NodeMethod(createThread),
        "markRead": NodeMethod(markRead),
        "muteThread": NodeMethod(muteThread),
        "deleteThread": NodeMethod(deleteThread),
        "sendTypingStatus": NodeMethod(sendTypingStatus),
        "watchThreadActivity": NodeMethod(watchThreadActivity),
        "setReaction": NodeMethod(setReaction),
        "sendTextMessage": NodeMethod(sendTextMessage),
        "sendFile": NodeMethod(sendFile),
        "sendReply": NodeMethod(sendReply),
        "notifyAnyway": NodeMethod(notifyAnyway),
        "dispose": NodeMethod(dispose)
    ]

    static let name = "MessagesController"

    private static let queue = DispatchQueue(label: "messages-controller-queue")

    private static func returnAsync(
        on jsQueue: NodeAsyncQueue,
        _ action: @escaping () throws -> NodeValueConvertible
    ) throws -> NodePromise {
        try NodePromise { deferred in
            queue.async {
                let result = Result { try action() }
                try? jsQueue.async {
                    try deferred(result)
                }
            }
        }
    }

    private func returnAsync(
        _ action: @escaping () throws -> NodeValueConvertible
    ) throws -> NodePromise {
        try Self.returnAsync(on: swiftJSQueue, action)
    }

    private func performAsync(
        _ action: @escaping () throws -> Void
    ) throws -> NodePromise {
        try returnAsync {
            try action()
            return NodeUndefined.deferred
        }
    }

    static func create(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        let q = try NodeAsyncQueue(label: "create-messages-controller")
        return try returnAsync(on: q) {
            let controller = try MessagesController()
            return NodeDeferredValue {
                try MessagesControllerWrapper(controller: controller).wrapped()
            }
        }
    }

    private var threadObserveRequestToken: UUID?
    private let threadObserveRequestTokenLock = NSLock()

    private let swiftJSQueue: NodeAsyncQueue
    private let watchCBQueue: NodeAsyncQueue

    let controller: MessagesController
    // must be called on JS queue
    init(controller: MessagesController) throws {
        self.controller = controller
        self.swiftJSQueue = try NodeAsyncQueue(label: "messages-controller-async")
        self.watchCBQueue = try NodeAsyncQueue(label: "watch-imessage-callback")
    }

    func isValid() throws -> NodeValueConvertible {
        try returnAsync { self.controller.isValid }
    }

    func createThread(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        guard args.count == 2,
              let addresses = try args[0].as([String].self),
              let message = try args[1].as(String.self) else {
            throw ErrorMessage("Bad MessagesController call: \(#function)")
        }
        return try performAsync {
            try self.controller.createThread(addresses: addresses, message: message)
        }
    }

    func markRead(messageGUID: String) throws -> NodeValueConvertible {
        try performAsync { try self.controller.markAsRead(messageGUID: messageGUID) }
    }

    func muteThread(threadID: String, muted: Bool) throws -> NodeValueConvertible {
        try performAsync { try self.controller.muteThread(threadID: threadID, muted: muted) }
    }

    func deleteThread(threadID: String) throws -> NodeValueConvertible {
        try performAsync { try self.controller.deleteThread(threadID: threadID) }
    }

    func sendTypingStatus(isTyping: Bool, address: String) throws -> NodeValueConvertible {
        try performAsync { try self.controller.sendTypingStatus(isTyping, address: address) }
    }

    func notifyAnyway(threadID: String) throws -> NodeValueConvertible {
        try performAsync { try self.controller.notifyAnyway(threadID: threadID) }
    }

    func watchThreadActivity(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        let controllerArgs: (String, ([MessagesController.ActivityStatus]) -> Void)?
        if try args.count == 1 && args[0].as(NodeNull.self) != nil {
            controllerArgs = nil
        } else if args.count == 2,
                  let address = try args[0].as(String.self),
                  let fn = try args[1].as(NodeFunction.self) {
            controllerArgs = (address, { status in
                try? self.watchCBQueue.async { try fn(status.map { $0.rawValue }) }
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
            if let (address, callback) = controllerArgs {
                try controller.observe(address: address, callback: callback)
            } else {
                try controller.removeObserver()
            }
        }
    }

    func setReaction(messageGUID: String, offset: Double, cellID: String, cellRole: String, overlay: Bool, reactionName: String, on: Bool) throws -> NodeValueConvertible {
        guard let reaction = MessagesController.Reaction(rawValue: reactionName) else {
            throw ErrorMessage("Invalid reaction: \(reactionName)")
        }
        return try performAsync { [self] in
            try controller.setReaction(messageGUID: messageGUID, offset: Int(offset), cellID: cellID == "" ? nil : cellID, cellRole: cellRole == "" ? nil : cellRole, overlay: overlay, reaction: reaction, on: on)
        }
    }

    func sendTextMessage(text: String, threadID: String) throws -> NodeValueConvertible {
        try performAsync { try self.controller.sendTextMessage(text, threadID: threadID) }
    }

    func sendFile(filePath: String, threadID: String) throws -> NodeValueConvertible {
        try performAsync { try self.controller.sendFile(filePath, threadID: threadID) }
    }

    func sendReply(threadID: String, messageGUID: String, offset: Double, cellID: String, cellRole: String, overlay: Bool, text: String, filePath: String) throws -> NodeValueConvertible {
        try performAsync {
            try self.controller.sendReply(
                threadID: threadID,
                messageGUID: messageGUID,
                offset: Int(offset),
                cellID: cellID == "" ? nil : cellID,
                cellRole: cellRole == "" ? nil : cellRole,
                overlay: overlay,
                text: text == "" ? nil : text,
                filePath: filePath == "" ? nil : filePath
            )
        }
    }

    func dispose() throws -> NodeValueConvertible {
        Self.queue.sync { controller.dispose() }
        return NodeUndefined.deferred
    }
}

@main struct SwiftServer: NodeModule {
    static var isLoggingEnabled = false
    static var isPHTEnabled = false

    let exports: NodeValueConvertible

    init() throws {
        // strongly retained by askForMessagesDirAccess, deinit called on exit
        let accessManager = MessagesAccessManager()

        var onboardingManager: OnboardingManager? = nil

        exports = try NodeObject([
            "appleInterfaceStyle": NodeComputedProperty { _ in
                UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
            },

            "isLoggingEnabled": NodeComputedProperty { _ in
                Self.isLoggingEnabled
            } set: { args in
                Self.isLoggingEnabled = try args.first?.as(Bool.self) ?? false
            },

            "isPHTEnabled": NodeComputedProperty { _ in
                Self.isPHTEnabled
            } set: { args in
                Self.isPHTEnabled = try args.first?.as(Bool.self) ?? false
            },

            "askForMessagesDirAccess": NodeFunction { _ in
                let queue = try NodeAsyncQueue(label: "messages-dir-callback")
                return try NodePromise { deferred in
                    DispatchQueue.main.async {
                        let result = Result<NodeValueConvertible, Error> {
                            try accessManager.requestAccess()
                            return NodeUndefined.deferred
                        }
                        try? queue.async {
                            try deferred(result)
                        }
                    }
                }
            },

            "decodeAttributedString": NodeFunction { args in
                guard let data = try args.first?.as(Data.self),
                      let decoded = try? AttributedStringDecoder.decodeAttributedString(from: data) else {
                    return try NodeUndefined()
                }
                return try decoded.map { frag in
                    try NodeObject([
                        "from": Double(frag.scalarRange.lowerBound),
                        "to": Double(frag.scalarRange.upperBound),
                        "text": "\(frag.text)",
                        "attributes": frag.attributes.mapValues { "\($0)" }
                    ])
                }
            },

            "MessagesController": MessagesControllerWrapper.constructor(),

            "startSysPrefsOnboarding": NodeFunction { _ in
                let queue = try NodeAsyncQueue(label: "sys-prefs-callback")
                return try NodePromise { deferred in
                    DispatchQueue.main.async {
                        let result = Result<NodeValueConvertible, Error> {
                            guard onboardingManager == nil else {
                                return NodeUndefined.deferred
                            }
                            onboardingManager = OnboardingManager()
                            if let onboardingManager = onboardingManager {
                                onboardingManager.createWindow()
                            }
                            return NodeUndefined.deferred
                        }
                        try? queue.async {
                            try deferred(result)
                        }
                    }
                }
            },

            "stopSysPrefsOnboarding": NodeFunction { _ in
                onboardingManager?.closeWindow()
                onboardingManager = nil
                return try NodeUndefined()
            },

            "confirmUNCPrompt": NodeFunction { _ in
                let queue = try NodeAsyncQueue(label: "prompt-automation-callback")
                return try NodePromise { deferred in
                    DispatchQueue.main.async {
                        let result = Result<NodeValueConvertible, Error> {
                            try PromptAutomation.confirmUNCPrompt()
                            return NodeUndefined.deferred
                        }
                        try? queue.async {
                            try deferred(result)
                        }
                    }
                }
            }
        ])
    }
}
