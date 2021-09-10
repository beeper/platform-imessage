import NodeAPI
import Foundation

@main struct SwiftServer: NodeModule {
    let exports: NodeValueConvertible
    static let queue = DispatchQueue(label: "swift-server-queue")

    static func decodeAttributedString(from data: Data) throws -> [NodeObject]? {
        // TODO: Make async, return promise
        guard let decoded = try queue.sync(
                execute: { try AttributedStringDecoder.decodeAttributedString(from: data) }
        ) else { return nil }
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
                print("MessagesController has been invalidated. Recreating...")
                let controller = try MessagesController()
                _controller = controller
                return controller
            }
        }
        exports = [
            "init": try NodeFunction(in: context) { ctx, info in
                print("initializing SwiftServer...")
                let deferred = try NodePromise.Deferred(in: ctx)
                let tsfn = try NodeThreadsafeFunction<Error?>(
                    asyncResourceName: "swift_server_init", in: ctx
                ) { ctx, err in
                    if let err = err {
                        // TODO: Use an actual NodeError
                        try deferred.reject(with: "\(err)", in: ctx)
                    } else {
                        try deferred.resolve(with: NodeUndefined(in: ctx), in: ctx)
                    }
                }
                Self.queue.async {
                    do {
                        _controller = try .init()
                    } catch {
                        try? tsfn(error)
                        return
                    }
                    try? tsfn(nil)
                }
                return deferred.promise
            },
            "decodeAttributedString": try NodeFunction(in: context) { ctx, info in
                guard let buffer = try info.arguments.first?.as(NodeBuffer.self),
                      let decoded = try Self.decodeAttributedString(from: buffer.data()) else {
                    return try NodeUndefined(in: ctx)
                }
                return decoded
            },
            "markRead": try NodeFunction(in: context) { ctx, info in
                guard let guid = try info.arguments.first?.as(NodeString.self) else {
                    return try NodeUndefined(in: ctx)
                }
                let guidString = try guid.string()
                // TODO: make async, return a promise
                try Self.queue.sync { try controller().markAsRead(guid: guidString) }
                return try NodeUndefined(in: ctx)
            },
            "dispose": try NodeFunction(in: context) { ctx, info in
                print("disposing SwiftServer...")
                Self.queue.sync { _controller = nil }
                return try NodeUndefined(in: ctx)
            }
        ]
    }
}
