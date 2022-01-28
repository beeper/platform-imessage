import Foundation
import CWindowControl

public class Space: Hashable {
    public enum Error: Swift.Error {
        case invalid
        case listFailed
    }

    public enum Kind {
        case user
        case fullscreen
        case system

        public var raw: CGSSpaceType {
            switch self {
            case .user: return CGSSpaceTypeUser
            case .fullscreen: return CGSSpaceTypeFullscreen
            case .system: return CGSSpaceTypeSystem
            }
        }

        public init?(raw: CGSSpaceType) {
            switch raw {
            case CGSSpaceTypeUser: self = .user
            case CGSSpaceTypeFullscreen: self = .fullscreen
            case CGSSpaceTypeSystem: self = .system
            default: return nil
            }
        }
    }

    public struct ListOptions: OptionSet {
        public let rawValue: UInt32
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        init(_ raw: CGSSpaceMask) {
            self.init(rawValue: raw.rawValue)
        }
        var raw: CGSSpaceMask { .init(rawValue) }

        public static let includesCurrent = Self(CGSSpaceIncludesCurrent)
        public static let includesOthers = Self(CGSSpaceIncludesOthers)
        public static let includesUser = Self(CGSSpaceIncludesUser)
        public static let onlyVisible = Self(CGSSpaceVisible)

        public static let currentSpaces: ListOptions = [.includesCurrent, .includesUser]
        public static let otherSpaces: ListOptions = [.includesCurrent, .includesOthers]
        public static let allSpaces: ListOptions = [.includesCurrent, .includesOthers, .includesUser]
        public static let allVisibleSpaces: ListOptions = [.allSpaces, .onlyVisible]
    }

    public static func active(for connection: GraphicsConnection = .main) throws -> Space {
        try Space(raw: CGSGetActiveSpace(connection.raw)).orThrow(Error.invalid)
    }

    public let raw: CGSSpaceID
    private let destroyWhenDone: Bool

    public init?(raw: CGSSpaceID) {
        guard raw != 0 else { return nil }
        self.raw = raw
        self.destroyWhenDone = false
    }

    public static func == (lhs: Space, rhs: Space) -> Bool {
        lhs.raw == rhs.raw
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(raw)
    }

    public init(
        newSpaceOfKind kind: Kind,
        destroyWhenDone: Bool = true,
        display: Display = .main,
        connection: GraphicsConnection = .main
    ) throws {
        raw = CGSSpaceCreate(
            // honestly not yet sure why this has to be 1
            connection.raw, UnsafeMutableRawPointer(bitPattern: 1),
            [
                "type": kind.raw.rawValue as CFNumber,
                "uuid": try display.uuid() as CFString
            ] as CFDictionary
        )
        debugLog("[spaces] created space id=\(raw) destroyWhenDone=\(destroyWhenDone)")
        self.destroyWhenDone = destroyWhenDone
    }

    public func level(for connection: GraphicsConnection = .main) -> Int32 {
        CGSSpaceGetAbsoluteLevel(connection.raw, raw)
    }

    public func setLevel(for connection: GraphicsConnection = .main, level: Int32) {
        CGSSpaceSetAbsoluteLevel(connection.raw, raw, level)
    }

    public func destroy(for connection: GraphicsConnection = .main) {
        CGSSpaceDestroy(connection.raw, raw)
    }

    public func kind(for connection: GraphicsConnection = .main) throws -> Kind {
        try Space.Kind(raw: CGSSpaceGetType(connection.raw, raw)).orThrow(Error.invalid)
    }

    public func name(for connection: GraphicsConnection = .main) throws -> String {
        try CGSSpaceCopyName(connection.raw, raw).orThrow(Error.invalid).takeRetainedValue() as String
    }

    public func owners(for connection: GraphicsConnection = .main) throws -> [pid_t] {
        guard let owners = CGSSpaceCopyOwners(connection.raw, raw)?.takeRetainedValue() as? [pid_t] else {
            throw Error.invalid
        }
        return owners
    }

    public static func list(
        _ options: ListOptions = .allSpaces,
        for connection: GraphicsConnection = .main
    ) throws -> [Space] {
        guard let ids = CGSCopySpaces(connection.raw, options.raw)?.takeRetainedValue() as? [CGSSpaceID]
        else { throw Error.listFailed }
        return try ids.map { try Space(raw: $0).orThrow(Error.listFailed) }
    }

    deinit {
        if destroyWhenDone {
            debugLog("[spaces] destroying space id=\(raw)")
            destroy()
        }
    }

    // doesn't work on regular spaces
    //    public func setName(_ name: String?, for connection: GraphicsConnection = .main) throws {
    //        try GraphicsConnection.check(CGSSpaceSetName(connection.raw, raw, name as CFString?))
    //    }

    // very easy to misuse
    //    public func show(for connection: GraphicsConnection = .main) {
    //        CGSShowSpaces(connection.raw, [raw] as CFArray)
    //    }
    //
    //    public func hide(for connection: GraphicsConnection = .main) {
    //        CGSHideSpaces(connection.raw, [raw] as CFArray)
    //    }
}
