import NodeAPI
import Foundation

@main struct SwiftServer: NodeModule {
    let exports: NodeValueConvertible

    init() throws {
        var threadObserveRequestToken: UUID?
        let threadObserveRequestTokenLock = NSLock()
        var _controller: MessagesController?
        func controller() throws -> MessagesController {
            guard let controller = _controller else {
                throw ErrorMessage("MessagesController used while uninitialized")
            }
            // reinitialize if the saved instance of Messages has been quit
            if controller.isValid {
                return controller
            } else {
                debugLog("MessagesController has been invalidated. Recreating...")
                let controller = try MessagesController()
                _controller = controller
                return controller
            }
        }
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
        exports = try NodeObject([
            "init": NodeFunction { args in
                if args.count == 1,
                   let isLoggingEnabled = try? args[0].as(Bool.self) {
                    gIsLoggingEnabled = isLoggingEnabled
                }
                debugLog("initializing SwiftServer...")
                return try performAsync {
                    if _controller == nil {
                        _controller = try .init()
                    }
                }
            },

            "decodeAttributedString": NodeFunction { args in
                guard let data = try args.first?.as(Data.self),
                      let decoded = try? AttributedStringDecoder.decodeAttributedString(from: data) else {
                    return try NodeUndefined()
                }
                return try decoded.map { frag -> NodeObject in
                    let obj = try NodeObject([
                        "from": Double(frag.scalarRange.lowerBound),
                        "to": Double(frag.scalarRange.upperBound),
                        "text": "\(frag.text)",
                        "attributes": frag.attributes.mapValues { "\($0)" }
                    ])
                    return obj
                }
            },

            "createThread": NodeFunction { args in
                guard args.count == 2,
                      let addresses = try args[0].as([String].self),
                      let message = try args[1].as(String.self) else {
                    return try NodeUndefined()
                }
                return try performAsync() {
                    try controller().createThread(addresses: addresses, message: message)
                }
            },

            "markRead": NodeFunction { args in
                guard let guid = try args.first?.as(String.self) else {
                    return try NodeUndefined()
                }
                return try performAsync {
                    try controller().markAsRead(guid: guid)
                }
            },

            "sendTypingStatus": NodeFunction { args in
                guard args.count == 2,
                      let isTyping = try? args[0].as(Bool.self),
                      let address = try? args[1].as(String.self)
                else { return try NodeUndefined() }
                return try performAsync {
                    try controller().sendTypingStatus(isTyping, address: address)
                }
            },

            "watchThreadActivity": NodeFunction { args in
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
                    let controller = try controller()
                    if let (address, callback) = controllerArgs {
                        try controller.observe(address: address, callback: callback)
                    } else {
                        try controller.removeObserver()
                    }
                }
            },

            "setReaction": NodeFunction { args in
                guard args.count == 4,
                      let guid = try? args[0].as(String.self),
                      let offset = try? args[1].as(Double.self),
                      let reactionName = try? args[2].as(String.self),
                      let reaction = MessagesController.Reaction(rawValue: reactionName),
                      let on = try? args[3].as(Bool.self) else {
                    return try NodeUndefined()
                }
                return try performAsync {
                    try controller().setReaction(guid: guid, offset: Int(offset), reaction: reaction, on: on)
                }
            },

            "sendTextMessage": NodeFunction { args in
                guard args.count == 2,
                      let text = try? args[0].as(String.self),
                      let threadID = try? args[1].as(String.self)
                else { return try NodeUndefined() }
                return try performAsync {
                    try controller().sendTextMessage(text, threadID: threadID)
                }
            },

            "sendReply": NodeFunction { args in
                guard args.count == 2,
                      let guid = try? args[0].as(String.self),
                      let text = try? args[1].as(String.self)
                else { return try NodeUndefined() }
                return try performAsync {
                    try controller().sendReply(guid: guid, text: text)
                }
            },

            "dispose": NodeFunction { args in
                debugLog("disposing SwiftServer...")
                MessagesController.queue.sync {
                    _controller?.dispose()
                    _controller = nil
                }
                return try NodeUndefined()
            }
        ])
    }
}
