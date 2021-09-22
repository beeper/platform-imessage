import Foundation
import CWindowControl

public struct Display {
    public enum Error: Swift.Error {
        case invalidDisplay
        case switchingToSameSpace
    }

    public static let main = Self(raw: CGMainDisplayID())

    public let raw: CGDirectDisplayID
    public init(raw: CGDirectDisplayID) {
        self.raw = raw
    }

    public func uuid() throws -> UUID {
        let uuid = try CGDisplayCreateUUIDFromDisplayID(raw).orThrow(Error.invalidDisplay).takeRetainedValue()
        return withUnsafePointer(to: CFUUIDGetUUIDBytes(uuid)) { buf in
            buf.withMemoryRebound(to: uuid_t.self, capacity: 1) { raw in
                UUID(uuid: raw.pointee)
            }
        }
    }
}
