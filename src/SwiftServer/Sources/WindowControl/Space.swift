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
        case unknown
        case tiled

        public var raw: CGSSpaceType {
            switch self {
            case .user: return CGSSpaceTypeUser
            case .fullscreen: return CGSSpaceTypeFullscreen
            case .system: return CGSSpaceTypeSystem
            case .unknown: return CGSSpaceTypeUnknown
            case .tiled: return CGSSpaceTypeTiled
            }
        }

        public init?(raw: CGSSpaceType) {
            switch raw {
            case CGSSpaceTypeUser: self = .user
            case CGSSpaceTypeFullscreen: self = .fullscreen
            case CGSSpaceTypeSystem: self = .system
            case CGSSpaceTypeUnknown: self = .unknown
            case CGSSpaceTypeTiled: self = .tiled
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
        public static let includesOS = Self(CGSSpaceIncludesOS)
        public static let onlyVisible = Self(CGSSpaceVisible)

        public static let currentSpaces: ListOptions = [.includesCurrent, .includesUser]
        public static let otherSpaces: ListOptions = [.includesCurrent, .includesOthers]
        public static let allSpaces: ListOptions = [.includesCurrent, .includesOthers, .includesUser]
        public static let allOSSpaces: ListOptions = [.includesCurrent, .includesOS, .includesOthers, .includesUser]
        public static let allVisibleSpaces: ListOptions = [.allSpaces, .onlyVisible]
    }

    public static func active(for connection: GraphicsConnection = .main) throws -> Space {
        try Space(raw: CGSGetActiveSpace(connection.raw)).orThrow(Error.invalid)
    }

    public let raw: CGSSpaceID
    private let destroyWhenDone: Bool

    // these two are used for self created spaces
    let isUnknownKind: Bool? // used to determine if to use CGSAddWindowsToSpaces/CGSRemoveWindowsFromSpaces or CGSMoveWindowsToManagedSpace
    public let dockPID: pid_t? // used for determining if the user space is visible

    public init?(raw: CGSSpaceID) {
        guard raw != 0 else { return nil }
        self.raw = raw
        self.isUnknownKind = nil
        self.dockPID = nil
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
        isUnknownKind = kind == .unknown
        var values: [String: Any] = [
            // "wsid": 1234 as CFNumber, // Compat ID
            // "ManagedSpaceID": 1234 as CFNumber, // will be ignored, spaces of unknown kind don't have this key
            // "id64": 1234 as CFNumber, // will be overridden
            "type": kind.raw.rawValue as CFNumber,
            "uuid": "Texts-\(UUID().uuidString)" as CFString, // another space with the same uuid can exist and the space will be created still
        ]
        if isUnknownKind == false {
            dockPID = Dock.getPID()
            values["dockPID"] = dockPID ?? 0 as CFNumber
        } else {
            dockPID = nil
        }
        raw = CGSSpaceCreate(
            connection.raw,
            // kind will be set to .unknown only when second arg is 1
            UnsafeMutableRawPointer(bitPattern: kind == .unknown ? 1 : 0),
            values as CFDictionary
        )
        self.destroyWhenDone = destroyWhenDone
        #if DEBUG
        debugLog("[spaces] created space id=\(raw) destroyWhenDone=\(destroyWhenDone) kind=\(kind) (\(kind.raw.rawValue))")
        self.printAttributes()
        #endif
    }

    public func values(for connection: GraphicsConnection = .main) throws -> CFDictionary {
        try CGSSpaceCopyValues(connection.raw, raw).orThrow(Error.invalid).takeRetainedValue()
    }
    public func setValues(for connection: GraphicsConnection = .main, _ values: [String: Any]) throws {
        try GraphicsConnection.check(CGSSpaceSetValues(connection.raw, raw, values as CFDictionary))
    }
    public func removeKeys(for connection: GraphicsConnection = .main, _ keys: [String]) throws {
        try GraphicsConnection.check(CGSSpaceRemoveValuesForKeys(connection.raw, raw, keys as CFArray))
    }

    public func level(for connection: GraphicsConnection = .main) -> Int32 {
        CGSSpaceGetAbsoluteLevel(connection.raw, raw)
    }
    public func level(for connection: GraphicsConnection = .main, assign level: Int32) {
        CGSSpaceSetAbsoluteLevel(connection.raw, raw, level)
    }

    public func destroy(for connection: GraphicsConnection = .main) {
        CGSSpaceDestroy(connection.raw, raw)
    }

    public func kind(for connection: GraphicsConnection = .main) throws -> Kind {
        try Space.Kind(raw: CGSSpaceGetType(connection.raw, raw)).orThrow(Error.invalid)
    }
    public func kind(for connection: GraphicsConnection = .main, assign value: Kind) {
        CGSSpaceSetType(connection.raw, raw, value.raw)
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

    public func compatID(for connection: GraphicsConnection = .main) -> Int32 {
        CGSSpaceGetCompatID(connection.raw, raw)
    }

    public static func list(
        _ options: ListOptions,
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
    // public func setName(_ name: String?, for connection: GraphicsConnection = .main) throws {
    //     try GraphicsConnection.check(CGSSpaceSetName(connection.raw, raw, name as CFString?))
    // }

    // NOTE(kabir): very easy to misuse show/hide
    public func show(for connection: GraphicsConnection = .main) {
        CGSShowSpaces(connection.raw, [raw] as CFArray)
    }
    public func hide(for connection: GraphicsConnection = .main) {
        CGSHideSpaces(connection.raw, [raw] as CFArray)
    }

    public func printAttributes() {
        debugLog("[space \(raw)] Name: \((try? name()) as Any)")
        debugLog("[space \(raw)] Kind: \((try? kind()) as Any)")
        debugLog("[space \(raw)] Owners: \((try? owners()) ?? [])")
        debugLog("[space \(raw)] Level: \(level())")
        debugLog("[space \(raw)] Compat ID: \(compatID())")
        debugLog("[space \(raw)] Values: \((try? values()) as Any)")
    }
}
