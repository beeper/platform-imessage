import Foundation
import NodeAPI
import SwiftServer
import SwiftServerFoundation

final class SendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

enum NodeBridgeUtilities {
    @NodeActor
    static func nodeArray(from values: [Any]) throws -> NodeArray {
        let array = try NodeArray(capacity: values.count)
        for (index, value) in values.enumerated() {
            try array[index].set(to: nodeValue(from: value))
        }
        return array
    }

    @NodeActor
    static func nodeObject(from dictionary: [String: Any]) throws -> NodeObject {
        let object = try NodeObject()
        for (key, value) in dictionary {
            try object[key].set(to: nodeValue(from: value))
        }
        return object
    }

    @NodeActor
    static func nodeValue(from value: Any) throws -> NodeValueConvertible {
        switch value {
        case let value as NodeValueConvertible:
            return value
        case let value as [String: Any]:
            return try nodeObject(from: value)
        case let value as [Any]:
            return try nodeArray(from: value)
        case is NSNull:
            return null
        default:
            throw ErrorMessage("Unsupported Node bridge value: \(type(of: value))")
        }
    }
}
