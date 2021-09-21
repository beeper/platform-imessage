import NodeAPI
import Foundation

@main struct SwiftServer: NodeModule {
    let exports: NodeValueConvertible

    static func decodeAttributedString(from data: Data) throws -> [NodeObject]? {
        // TODO: Make async, return promise
        guard let decoded = try AttributedStringDecoder.decodeAttributedString(from: data)
            else { return nil }
        return try decoded.map { frag in
            let obj = try NodeObject(in: .current)
            try obj.define(properties: [
                NodePropertyDescriptor(
                    name: "key",
                    attributes: .enumerable,
                    value: .data(frag.key)
                ),
                NodePropertyDescriptor(
                    name: "value",
                    attributes: .enumerable,
                    value: .data("\(frag.value)")
                ),
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
            ])
            return obj
        }
    }

    init(context: NodeContext) throws {
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
        func performAsync(with ctx: NodeContext, action: @escaping () throws -> Void) throws -> NodePromise {
            let deferred = try NodePromise.Deferred(in: ctx)
            let tsfn = try NodeThreadsafeFunction<Error?>(
                asyncResourceName: "swift_server_perform", in: ctx
            ) { ctx, err in
                if let err = err {
                    try deferred.reject(with: NodeError(code: "\(type(of: err))", message: "\(err)", in: ctx), in: ctx)
                } else {
                    try deferred.resolve(with: NodeUndefined(in: ctx), in: ctx)
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
            "init": try NodeFunction(in: context) { ctx, info in
                if info.arguments.count == 1,
                   let isLoggingEnabled = try? info.arguments[0].as(NodeBool.self)?.bool() {
                    gIsLoggingEnabled = isLoggingEnabled
                }
                debugLog("initializing SwiftServer...")
                return try performAsync(with: ctx) {
                    if _controller == nil {
                        _controller = try .init()
                    }
                }
            },
            "decodeAttributedString": try NodeFunction(in: context) { ctx, info in
                guard let buffer = try info.arguments.first?.as(NodeBuffer.self),
                      let decoded = try Self.decodeAttributedString(from: buffer.data()) else {
                    return try NodeUndefined(in: ctx)
                }
                return decoded
            },
            "createThread": try NodeFunction(in: context) { ctx, info in
                guard let arr = try info.arguments.first?.as(NodeArray.self) else {
                    return try NodeUndefined(in: ctx)
                }
                let addresses = try (0..<arr.count()).compactMap {
                    try arr[Double($0)].get(in: ctx).as(NodeString.self)?.string()
                }
                try MessagesController.queue.sync {
                    try controller().createThread(addresses: addresses)
                }
                return try NodeUndefined(in: ctx)
            },
            "markRead": try NodeFunction(in: context) { ctx, info in
                guard let guid = try info.arguments.first?.as(NodeString.self) else {
                    return try NodeUndefined(in: ctx)
                }
                let guidString = try guid.string()
                return try performAsync(with: ctx) {
                    try controller().markAsRead(guid: guidString)
                }
            },
            "sendTypingStatus": try NodeFunction(in: context) { ctx, info in
                guard info.arguments.count == 2,
                      let isTyping = try? info.arguments[0].as(NodeBool.self)?.bool(),
                      let address = try? info.arguments[1].as(NodeString.self)?.string()
                else { return try NodeUndefined(in: ctx) }
                try MessagesController.queue.sync {
                    try controller().sendTypingStatus(isTyping, address: address)
                }
                return try NodeUndefined(in: ctx)
            },
            "watchThreadActivity": try NodeFunction(in: context) { ctx, info in
                let args: (String, (MessagesController.ActivityStatus) -> Void)?
                if try info.arguments.count == 1 && info.arguments[0].as(NodeNull.self) != nil {
                    args = nil
                } else if info.arguments.count == 2,
                          let address = try info.arguments[0].as(NodeString.self),
                          let fn = try info.arguments[1].as(NodeFunction.self) {
                    let addressName = try address.string()
                    let tsfn = try NodeThreadsafeFunction<MessagesController.ActivityStatus>(
                        asyncResourceName: "watch_imessage_callback", in: ctx
                    ) { ctx, param in
                        try fn(in: ctx, param.rawValue)
                    }
                    args = (addressName, { try? tsfn($0) })
                } else {
                    print("warning: Invalid args to watchThreadActivity")
                    args = nil
                }
                try MessagesController.queue.sync {
                    let controller = try controller()
                    if let args = args {
                        try controller.observe(address: args.0, callback: args.1)
                    } else {
                        try controller.removeObserver()
                    }
                }
                return try NodeUndefined(in: ctx)
            },
            "setReaction": try NodeFunction(in: context) { ctx, info in
                guard info.arguments.count == 4,
                      let guid = try? info.arguments[0].as(NodeString.self)?.string(),
                      let offset = try? info.arguments[1].as(NodeNumber.self)?.double(),
                      let reactionName = try? info.arguments[2].as(NodeString.self)?.string(),
                      let reaction = MessagesController.Reaction(rawValue: reactionName),
                      let on = try? info.arguments[3].as(NodeBool.self)?.bool() else {
                    return try NodeUndefined(in: ctx)
                }
                try MessagesController.queue.sync {
                    try controller().setReaction(guid: guid, offset: Int(offset), reaction: reaction, on: on)
                }
                return try NodeUndefined(in: ctx)
            },
            "dispose": try NodeFunction(in: context) { ctx, info in
                debugLog("disposing SwiftServer...")
                MessagesController.queue.sync { _controller = nil }
                return try NodeUndefined(in: ctx)
            }
        ]
    }
}
