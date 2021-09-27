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

    private static func fetchDisplays(
        _ fetch: (CGDisplayCount, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<CGDisplayCount>) -> CGDisplayErr
    ) throws -> [Display] {
        var count: CGDisplayCount = 0
        try GraphicsConnection.check(fetch(0, nil, &count))
        guard count != 0 else { return [] }
        return try [CGDirectDisplayID](unsafeUninitializedCapacity: Int(count)) { buf, count in
            var outCount: CGDisplayCount {
                get { .init(count) }
                set { count = .init(newValue) }
            }
            try GraphicsConnection.check(fetch(outCount, buf.baseAddress!, &outCount))
        }.map(Display.init(raw:))
    }

    public static func allActive() throws -> [Display] {
        try fetchDisplays(CGSGetActiveDisplayList)
    }

    public static func allOnline() throws -> [Display] {
        try fetchDisplays(CGSGetOnlineDisplayList)
    }

    public func currentSpace(for connection: GraphicsConnection = .main) throws -> Space {
        let space = try CGSManagedDisplayGetCurrentSpace(connection.raw, uuid().uuidString as CFString)
        return try Space(raw: space).orThrow(Space.Error.invalid)
    }

    public func spaces(for connection: GraphicsConnection = .main) throws {
        let disps = CGSCopyManagedDisplaySpaces(connection.raw).takeRetainedValue() as? [Any]
        print(disps ?? [])
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
