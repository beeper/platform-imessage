import Foundation
import AppKit
import CWindowControl

extension UUID {
    public init(cfUUID: CFUUID) {
        self = withUnsafePointer(to: CFUUIDGetUUIDBytes(cfUUID)) { buf in
            buf.withMemoryRebound(to: uuid_t.self, capacity: 1) { raw in
                UUID(uuid: raw.pointee)
            }
        }
    }
}

public struct Display: Hashable {
    public enum Error: Swift.Error {
        case invalidDisplay
        case invalidMainDisplay
        case switchingToSameSpace
    }

    public static var main: Display { .init(raw: CGMainDisplayID()) }

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
        let space = try CGSManagedDisplayGetCurrentSpace(connection.raw, uuid() as CFString)
        return try Space(raw: space).orThrow(Space.Error.invalid)
    }

    public func spaces(for connection: GraphicsConnection = .main) throws {
        let disps = CGSCopyManagedDisplaySpaces(connection.raw).takeRetainedValue() as? [Any]
        print(disps ?? [])
    }

    public func uuid() throws -> String {
        if self == .main {
            // this isn't actually a UUID (it's "Main") so we can't return
            // an [NS]UUID
            return try kCGSPackagesMainDisplayIdentifier
                .flatMap { $0.takeUnretainedValue() as String? }
                .orThrow(Error.invalidMainDisplay)
        }
        let uuid = try CGDisplayCreateUUIDFromDisplayID(raw).orThrow(Error.invalidDisplay).takeRetainedValue()
        return UUID(cfUUID: uuid).uuidString
    }
}
