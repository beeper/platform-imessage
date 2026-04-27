import Foundation
import Logging
import NodeAPI
import SwiftServer
import SwiftServerFoundation

private let log = Logger(swiftServerLabel: "node-bridge")

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

    // Accept the Foundation types that surface in event payloads
    // (NSKeyedUnarchiver output, etc.). On an unrecognized type we coerce to a
    // string and breadcrumb rather than throw — a single bad value must not
    // sink the whole event batch.
    @NodeActor
    static func nodeValue(from value: Any) throws -> NodeValueConvertible {
        switch value {
        case is NSNull:
            return null
        case let value as NSString:
            return value as String
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue
            }
            let intValue = value.intValue
            if Double(intValue) == value.doubleValue {
                return intValue
            }
            return value.doubleValue
        case let value as Date:
            return value.timeIntervalSince1970 * 1000
        case let value as NSDate:
            return value.timeIntervalSince1970 * 1000
        case let value as Data:
            return "data:;base64,\(value.base64EncodedString())"
        case let value as NSData:
            return "data:;base64,\(value.base64EncodedString())"
        case let value as URL:
            return value.absoluteString
        case let value as NSURL:
            return value.absoluteString ?? ""
        case let value as NodeValueConvertible:
            return value
        case let value as [String: Any]:
            return try nodeObject(from: value)
        case let value as NSDictionary:
            var stringKeyed: [String: Any] = [:]
            for (key, child) in value {
                guard let stringKey = key as? String else { continue }
                stringKeyed[stringKey] = child
            }
            return try nodeObject(from: stringKeyed)
        case let value as [Any]:
            return try nodeArray(from: value)
        case let value as NSArray:
            return try nodeArray(from: Array(value))
        default:
            log.warning("coercing unsupported value to string: \(type(of: value))")
            return String(describing: value)
        }
    }
}
