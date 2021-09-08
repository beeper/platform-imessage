import NodeAPI
import Foundation

@main struct SwiftServer: NodeModule {
    let exports: NodeValueConvertible

    static func decodeAttributedString(from data: Data) throws -> [NodeObject]? {
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
        exports = [
            "decodeAttributedString": try NodeFunction(in: context) { ctx, info in
                guard let buffer = try info.arguments.first?.as(NodeBuffer.self),
                      let decoded = try Self.decodeAttributedString(from: buffer.data()) else {
                    return try NodeUndefined(in: ctx)
                }
                return decoded
            }
        ]
    }
}
