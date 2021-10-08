import NodeAPI
import Foundation

@main struct SwiftServer: NodeModule {
    let exports: NodeValueConvertible

    init() throws {
        var threadObserveRequestToken: UUID?
        let threadObserveRequestTokenLock = NSLock()

        let swiftJSQueue = try NodeAsyncQueue(label: "swift_server_perform")
        let watchCBQueue = try NodeAsyncQueue(label: "watch_imessage_callback")
        func performAsync(_ action: @escaping () throws -> Void) throws -> NodePromise {
            try NodePromise { deferred in
                MessagesController.queue.async {
                    let result = Result { try action() }
                    try? swiftJSQueue.async {
                        try deferred(result)
                    }
                }
            }
        }

        let key = NodeWrappedDataKey<MessagesController>()
        func controller(for args: NodeFunction.Arguments, line: UInt = #line) throws -> MessagesController {
            guard let controller = try args.this?.wrappedValue(forKey: key) else {
                throw ErrorMessage("Invalid controller for call at L\(line)")
            }
            return controller
        }

        let messagesControllerProps: NodeClassPropertyList = [
            "create": NodeMethod(attributes: .static) { args in
                guard let ctor = try args.this?.as(NodeFunction.self) else {
                    throw ErrorMessage("Invalid invocation of create")
                }
                return try NodePromise { deferred in
                    MessagesController.queue.async {
                        let result = Result { try MessagesController() }
                        try? swiftJSQueue.async {
                            try deferred(Result {
                                let controller = try result.get()
                                let obj = try NodeObject(constructor: ctor)
                                try obj.setWrappedValue(controller, forKey: key)
                                return obj
                            })
                        }
                    }
                }
            },

            "isValid": NodeMethod { args in
                let controller = try controller(for: args)
                return try NodePromise { deferred in
                    MessagesController.queue.async {
                        let isValid = controller.isValid
                        try? swiftJSQueue.async {
                            try deferred(.success(isValid))
                        }
                    }
                }
            },

            "createThread": NodeMethod { args in
                let controller = try controller(for: args)
                guard args.count == 2,
                      let addresses = try args[0].as([String].self),
                      let message = try args[1].as(String.self) else {
                          throw ErrorMessage("Bad MessagesController call: \(#line)")
                }
                return try performAsync() {
                    try controller.createThread(addresses: addresses, message: message)
                }
            },

            "markRead": NodeMethod { args in
                let controller = try controller(for: args)
                guard let guid = try args.first?.as(String.self) else {
                    return try NodeUndefined()
                }
                return try performAsync {
                    try controller.markAsRead(guid: guid)
                }
            },

            "sendTypingStatus": NodeMethod { args in
                let controller = try controller(for: args)
                guard args.count == 2,
                      let isTyping = try? args[0].as(Bool.self),
                      let address = try? args[1].as(String.self)
                else { return try NodeUndefined() }
                return try performAsync {
                    try controller.sendTypingStatus(isTyping, address: address)
                }
            },

            "watchThreadActivity": NodeMethod { args in
                let controller = try controller(for: args)
                let controllerArgs: (String, (MessagesController.ActivityStatus) -> Void)?
                if try args.count == 1 && args[0].as(NodeNull.self) != nil {
                    controllerArgs = nil
                } else if args.count == 2,
                          let address = try args[0].as(String.self),
                          let fn = try args[1].as(NodeFunction.self) {
                    controllerArgs = (address, { status in
                        try? watchCBQueue.async { try fn(status.rawValue) }
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
                return try performAsync {
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
            },

            "setReaction": NodeMethod { args in
                let controller = try controller(for: args)
                guard args.count == 4,
                      let guid = try? args[0].as(String.self),
                      let offset = try? args[1].as(Double.self),
                      let reactionName = try? args[2].as(String.self),
                      let reaction = MessagesController.Reaction(rawValue: reactionName),
                      let on = try? args[3].as(Bool.self) else {
                    return try NodeUndefined()
                }
                return try performAsync {
                    try controller.setReaction(guid: guid, offset: Int(offset), reaction: reaction, on: on)
                }
            },

            "sendTextMessage": NodeMethod { args in
                let controller = try controller(for: args)
                guard args.count == 2,
                      let text = try? args[0].as(String.self),
                      let threadID = try? args[1].as(String.self)
                else { return try NodeUndefined() }
                return try performAsync {
                    try controller.sendTextMessage(text, threadID: threadID)
                }
            },

            "sendReply": NodeMethod { args in
                let controller = try controller(for: args)
                guard args.count == 2,
                      let guid = try? args[0].as(String.self),
                      let text = try? args[1].as(String.self)
                else { return try NodeUndefined() }
                return try performAsync {
                    try controller.sendReply(guid: guid, text: text)
                }
            },

            "dispose": NodeMethod { args in
                let controller = try controller(for: args)
                MessagesController.queue.sync {
                    controller.dispose()
                }
                return try NodeUndefined()
            }
        ]

        exports = try NodeObject([
            "isLoggingEnabled": NodeComputedProperty { args in
                gIsLoggingEnabled
            } set: { args in
                gIsLoggingEnabled = try args.first?.as(Bool.self) ?? false
                return try NodeUndefined()
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

            "MessagesController": try NodeFunction(
                className: "MessagesController",
                properties: messagesControllerProps,
                constructor: { _ in }
            )
        ])
    }
}
