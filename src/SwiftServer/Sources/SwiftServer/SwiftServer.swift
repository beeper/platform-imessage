import NodeAPI
import Foundation

@main struct SwiftServer: NodeModule {
    let exports: NodeValueConvertible

    static func decodeAttributedString(from data: Data) throws -> [NodeObject]? {
        // TODO: Make async, return promise
        guard let decoded = try AttributedStringDecoder.decodeAttributedString(from: data)
            else { return nil }
        return try decoded.map { frag in
            let obj = try NodeObject()
            try obj.define(properties: [
                NodePropertyDescriptor(
                    name: "from",
                    attributes: .enumerable,
                    value: .data(Double(frag.scalarRange.lowerBound))
                ),
                NodePropertyDescriptor(
                    name: "to",
                    attributes: .enumerable,
                    value: .data(Double(frag.scalarRange.upperBound))
                ),
                NodePropertyDescriptor(
                    name: "text",
                    attributes: .enumerable,
                    value: .data(String(frag.text))
                ),
                NodePropertyDescriptor(
                    name: "attributes",
                    attributes: .enumerable,
                    value: .data(frag.attributes.mapValues { "\($0)" })
                ),
            ])
            return obj
        }
    }

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
        func performAsync(_ action: @escaping () throws -> Void) throws -> NodePromise {
            let deferred = try NodePromise.Deferred()
            let tsfn = try NodeThreadsafeFunction<Error?>(
                asyncResourceName: "swift_server_perform"
            ) { err in
                if let err = err {
                    try deferred.reject(with: NodeError(code: "\(type(of: err))", message: "\(err)"))
                } else {
                    try deferred.resolve(with: NodeUndefined())
                }
            }
            MessagesController.queue.async {
                do {
                    try action()
                } catch {
                    try? tsfn(error)
                    return
                }
                try? tsfn(nil)
            }
            return deferred.promise
        }
        exports = [
            "init": try NodeFunction { info in
                if info.arguments.count == 1,
                   let isLoggingEnabled = try? info.arguments[0].as(NodeBool.self)?.bool() {
                    gIsLoggingEnabled = isLoggingEnabled
                }
                debugLog("initializing SwiftServer...")
                return try performAsync {
                    if _controller == nil {
                        _controller = try .init()
                    }
                }
            },
            "decodeAttributedString": try NodeFunction { info in
                guard let buffer = try info.arguments.first?.as(NodeBuffer.self),
                      let decoded = try Self.decodeAttributedString(from: buffer.data()) else {
                    return try NodeUndefined()
                }
                return decoded
            },
            "createThread": try NodeFunction { info in
                guard info.arguments.count == 2,
                      let arr = try info.arguments[0].as(NodeArray.self),
                      let message = try info.arguments[1].as(NodeString.self)?.string() else {
                    return try NodeUndefined()
                }
                let addresses = try (0..<arr.count()).compactMap {
                    try arr[Double($0)].get().as(NodeString.self)?.string()
                }
                return try performAsync() {
                    try controller().createThread(addresses: addresses, message: message)
                }
            },
            "markRead": try NodeFunction { info in
                guard let guid = try info.arguments.first?.as(NodeString.self) else {
                    return try NodeUndefined()
                }
                let guidString = try guid.string()
                return try performAsync {
                    try controller().markAsRead(guid: guidString)
                }
            },
            "sendTypingStatus": try NodeFunction { info in
                guard info.arguments.count == 2,
                      let isTyping = try? info.arguments[0].as(NodeBool.self)?.bool(),
                      let address = try? info.arguments[1].as(NodeString.self)?.string()
                else { return try NodeUndefined() }
                return try performAsync {
                    try controller().sendTypingStatus(isTyping, address: address)
                }
            },
            "watchThreadActivity": try NodeFunction { info in
                let args: (String, (MessagesController.ActivityStatus) -> Void)?
                if try info.arguments.count == 1 && info.arguments[0].as(NodeNull.self) != nil {
                    args = nil
                } else if info.arguments.count == 2,
                          let address = try info.arguments[0].as(NodeString.self),
                          let fn = try info.arguments[1].as(NodeFunction.self) {
                    let addressName = try address.string()
                    let tsfn = try NodeThreadsafeFunction<MessagesController.ActivityStatus>(
                        asyncResourceName: "watch_imessage_callback"
                    ) { param in
                        try fn(param.rawValue)
                    }
                    args = (addressName, { try? tsfn($0) })
                } else {
                    print("warning: Invalid args to watchThreadActivity")
                    args = nil
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
                    if let args = args {
                        try controller.observe(address: args.0, callback: args.1)
                    } else {
                        try controller.removeObserver()
                    }
                }
            },
            "setReaction": try NodeFunction { info in
                guard info.arguments.count == 4,
                      let guid = try? info.arguments[0].as(NodeString.self)?.string(),
                      let offset = try? info.arguments[1].as(NodeNumber.self)?.double(),
                      let reactionName = try? info.arguments[2].as(NodeString.self)?.string(),
                      let reaction = MessagesController.Reaction(rawValue: reactionName),
                      let on = try? info.arguments[3].as(NodeBool.self)?.bool() else {
                    return try NodeUndefined()
                }
                return try performAsync {
                    try controller().setReaction(guid: guid, offset: Int(offset), reaction: reaction, on: on)
                }
            },
            "sendTextMessage": try NodeFunction { info in
                guard info.arguments.count == 2,
                      let text = try? info.arguments[0].as(NodeString.self)?.string(),
                      let threadID = try? info.arguments[1].as(NodeString.self)?.string()
                else { return try NodeUndefined() }
                return try performAsync {
                    try controller().sendTextMessage(text, threadID: threadID)
                }
            },
            "sendReply": try NodeFunction { info in
                guard info.arguments.count == 2,
                      let guid = try? info.arguments[0].as(NodeString.self)?.string(),
                      let text = try? info.arguments[1].as(NodeString.self)?.string()
                else { return try NodeUndefined() }
                return try performAsync {
                    try controller().sendReply(guid: guid, text: text)
                }
            },
            "dispose": try NodeFunction { info in
                debugLog("disposing SwiftServer...")
                MessagesController.queue.sync {
                    _controller?.dispose()
                    _controller = nil
                }
                return try NodeUndefined()
            }
        ]
    }
}
