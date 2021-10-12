import NodeAPI
import Foundation

final class MessagesControllerWrapper: NodeClass {
    static let properties: NodeClassPropertyList = [
        "create": NodeMethod(attributes: .static, create),
        "isValid": NodeMethod(isValid),
        "createThread": NodeMethod(createThread),
        "markRead": NodeMethod(markRead),
        "sendTypingStatus": NodeMethod(sendTypingStatus),
        "watchThreadActivity": NodeMethod(watchThreadActivity),
        "setReaction": NodeMethod(setReaction),
        "sendTextMessage": NodeMethod(sendTextMessage),
        "sendReply": NodeMethod(sendReply),
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
        try Self.returnAsync(on: swiftJSQueue) {
            try action()
            return NodeDeferredValue { try NodeUndefined() }
        }
    }

    static func create(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        guard let ctor = try args.this?.as(NodeFunction.self) else {
            throw ErrorMessage("Invalid invocation of create")
        }
        let q = try NodeAsyncQueue(label: "create-messages-controller")
        return try returnAsync(on: q) {
            let controller = try MessagesController()
            return NodeDeferredValue {
                try ctor.new(NodeExternal(value: controller))
            }
        }
    }

    private var threadObserveRequestToken: UUID?
    private let threadObserveRequestTokenLock = NSLock()

    private let swiftJSQueue: NodeAsyncQueue
    private let watchCBQueue: NodeAsyncQueue

    let controller: MessagesController
    init(_ args: NodeFunction.Arguments) throws {
        guard let controller = try args[0].as(NodeExternal.self)?.value() as? MessagesController else {
            throw ErrorMessage("MessagesController was not constructed using create()")
        }
        self.controller = controller
        self.swiftJSQueue = try NodeAsyncQueue(label: "messages-controller-async")
        self.watchCBQueue = try NodeAsyncQueue(label: "watch-imessage-callback")
    }

    func isValid(_: NodeFunction.Arguments) throws -> NodeValueConvertible {
        try returnAsync { self.controller.isValid }
    }

    func createThread(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        guard args.count == 2,
              let addresses = try args[0].as([String].self),
              let message = try args[1].as(String.self) else {
                  throw ErrorMessage("Bad MessagesController call: \(#function)")
        }
        return try performAsync { [self] in
            try controller.createThread(addresses: addresses, message: message)
        }
    }

    func markRead(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        guard args.count == 1,
              let guid = try args[0].as(String.self) else {
            return try NodeUndefined()
        }
        return try performAsync { [self] in
            try controller.markAsRead(guid: guid)
        }
    }

    func sendTypingStatus(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        guard args.count == 2,
              let isTyping = try args[0].as(Bool.self),
              let address = try args[1].as(String.self)
        else { return try NodeUndefined() }
        return try performAsync { [self] in
            try controller.sendTypingStatus(isTyping, address: address)
        }
    }

    func watchThreadActivity(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        let controllerArgs: (String, (MessagesController.ActivityStatus) -> Void)?
        if try args.count == 1 && args[0].as(NodeNull.self) != nil {
            controllerArgs = nil
        } else if args.count == 2,
                  let address = try args[0].as(String.self),
                  let fn = try args[1].as(NodeFunction.self) {
            controllerArgs = (address, { status in
                try? self.watchCBQueue.async { try fn(status.rawValue) }
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

    func setReaction(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        guard args.count == 4,
              let guid = try args[0].as(String.self),
              let offset = try args[1].as(Double.self),
              let reactionName = try args[2].as(String.self),
              let reaction = MessagesController.Reaction(rawValue: reactionName),
              let on = try args[3].as(Bool.self) else {
            return try NodeUndefined()
        }
        return try performAsync { [self] in
            try controller.setReaction(guid: guid, offset: Int(offset), reaction: reaction, on: on)
        }
    }

    func sendTextMessage(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        guard args.count == 2,
              let text = try? args[0].as(String.self),
              let threadID = try? args[1].as(String.self)
        else { return try NodeUndefined() }
        return try performAsync { [self] in
            try controller.sendTextMessage(text, threadID: threadID)
        }
    }

    func sendReply(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        guard args.count == 2,
              let guid = try args[0].as(String.self),
              let text = try args[1].as(String.self)
        else { return try NodeUndefined() }
        return try performAsync { [self] in
            try controller.sendReply(guid: guid, text: text)
        }
    }

    func dispose(_ args: NodeFunction.Arguments) throws -> NodeValueConvertible {
        Self.queue.sync { controller.dispose() }
        return try NodeUndefined()
    }
}

@main struct SwiftServer: NodeModule {
    static var isLoggingEnabled = false

    let exports: NodeValueConvertible

    init() throws {
        exports = try NodeObject([
            "isLoggingEnabled": NodeComputedProperty { _ in
                Self.isLoggingEnabled
            } set: { args in
                Self.isLoggingEnabled = try args.first?.as(Bool.self) ?? false
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

            "MessagesController": MessagesControllerWrapper.constructor()
        ])
    }
}
