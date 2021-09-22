import Foundation
import CWindowControl

public struct Window {
    public enum Error: Swift.Error {
        case listingFailed
        case windowNotFound
        case windowOnMultipleSpaces
        case missingKey(String)
        case invalidValue(key: String)
    }

    public struct ID: Hashable {
        public let raw: CGWindowID
        public init(_ raw: CGWindowID) {
            self.raw = raw
        }

        public static func list(_ options: ListOptions = .all, excludeDesktopElements: Bool = false) throws -> [ID] {
            var (rawOptions, windowID) = options.raw
            if excludeDesktopElements {
                rawOptions.formUnion(.excludeDesktopElements)
            }
            // TODO: Is takeRetainedValue the correct variant here?
            guard let arr = TXTWindowListCreate(rawOptions, windowID).takeRetainedValue() as? [CGWindowID] else {
                throw Error.listingFailed
            }
            return arr.map(Self.init(_:))
        }
    }

    public struct BackingStore {
        public enum Kind {
            case retained
            case nonretained
            case buffered

            init?(raw: CGWindowBackingType) {
                switch raw {
                case .backingStoreRetained:
                    self = .retained
                case .backingStoreNonretained:
                    self = .nonretained
                case .backingStoreBuffered:
                    self = .buffered
                @unknown default:
                    return nil
                }
            }
        }
        public let kind: Kind
        public let isInVideoMemory: Bool?
    }

    public enum SharingType {
        case none
        case readOnly
        case readWrite

        init?(raw: CGWindowSharingType) {
            switch raw {
            case .none:
                self = .none
            case .readOnly:
                self = .readOnly
            case .readWrite:
                self = .readWrite
            @unknown default:
                return nil
            }
        }
    }

    public enum ListOptions {
        case all
        case onScreen
        case onScreenAbove(Window.ID, orEqual: Bool)
        case onScreenBelow(Window.ID, orEqual: Bool)

        var raw: (CGWindowListOption, CGWindowID) {
            switch self {
            case .all:
                return (.optionAll, kCGNullWindowID)
            case .onScreen:
                return (.optionOnScreenOnly, kCGNullWindowID)
            case let .onScreenAbove(id, orEqual):
                return (.optionOnScreenAboveWindow.union(orEqual ? .optionIncludingWindow : []), id.raw)
            case let .onScreenBelow(id, orEqual):
                return (.optionOnScreenBelowWindow.union(orEqual ? .optionIncludingWindow : []), id.raw)
            }
        }
    }

    public let id: ID
    public let name: String?

    public let store: BackingStore
    public let sharingState: SharingType

    public let layer: Int
    public let bounds: CGRect
    public let alpha: Float
    public let isOnscreen: Bool?

    public let memoryUsage: Int64

    public let owner: pid_t
    public let ownerName: String?

    private static var connection = CGSMainConnectionID()

    public init(rawDescriptor: [String: Any]) throws {
        func get<T>(_ key: CFString, _ type: T.Type) throws -> T {
            try (rawDescriptor[key as String] as? T)
                .orThrow(Error.missingKey(key as String))
        }

        let rawID = try get(kCGWindowNumber, CGWindowID.self)
        self.id = ID(rawID)

        self.name = try? get(kCGWindowName, String.self)

        let rawStoreKind = try get(kCGWindowStoreType, UInt32.self)
        guard let cgStoreKind = CGWindowBackingType(rawValue: rawStoreKind),
              let storeKind = BackingStore.Kind(raw: cgStoreKind)
        else { throw Error.invalidValue(key: kCGWindowStoreType as String) }
        let isInVideoMemory = try? get(kCGWindowBackingLocationVideoMemory, Bool.self)
        self.store = .init(kind: storeKind, isInVideoMemory: isInVideoMemory)

        let rawSharingState = try get(kCGWindowSharingState, UInt32.self)
        guard let cgSharingState = CGWindowSharingType(rawValue: rawSharingState),
              let sharingState = SharingType(raw: cgSharingState)
        else { throw Error.invalidValue(key: kCGWindowSharingState as String) }
        self.sharingState = sharingState

        self.layer = try get(kCGWindowLayer, Int.self)

        let boundsDict = try get(kCGWindowBounds, CFDictionary.self)
        guard let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
            throw Error.invalidValue(key: kCGWindowBounds as String)
        }
        self.bounds = bounds

        self.alpha = try get(kCGWindowAlpha, Float.self)

        self.isOnscreen = try? get(kCGWindowIsOnscreen, Bool.self)

        self.memoryUsage = try get(kCGWindowMemoryUsage, CLongLong.self)

        self.owner = try get(kCGWindowOwnerPID, CInt.self)

        self.ownerName = try? get(kCGWindowOwnerName, String.self)
    }

    public init(id: ID) throws {
        self = try Self.list().first { $0.id == id }.orThrow(Error.windowNotFound)
//        guard let array = CGWindowListCreateDescriptionFromArray([id.raw] as CFArray) as? [[String: Any]],
//              array.count == 1 else { throw Error.windowNotFound }
//        try self.init(rawDescriptor: array[0])
//        // this should always be true since we asked for exactly one window and got
//        // one back, but it's an extra sanity check
//        guard self.id == id else { throw Error.windowNotFound }
    }

    // only works for our own windows?
    public func setAlpha(_ alpha: CGFloat, for connection: GraphicsConnection = .main) throws {
        if alpha < 1 {
            try GraphicsConnection.check(CGSSetWindowOpacity(connection.raw, id.raw, false))
        }
        try GraphicsConnection.check(CGSSetWindowAlpha(connection.raw, id.raw, alpha))
    }

    public func currentSpaces(for connection: GraphicsConnection = .main) throws -> [Space] {
        guard let rawSpaces = CGSCopySpacesForWindows(connection.raw, kCGSAllSpacesMask, [id.raw] as CFArray)?
                .takeRetainedValue() as? [CGSSpaceID]
        else { throw Error.windowNotFound }
        return rawSpaces.map { Space(raw: $0) }
    }

    public func moveToSpace(_ space: Space, for connection: GraphicsConnection = .main) throws {
        let curr = try currentSpaces(for: connection)
        guard curr.count == 1 else { throw Error.windowOnMultipleSpaces }
        let curSpace = curr[0]
        // no-op
        guard space != curSpace else { return }
        CGSAddWindowsToSpaces(connection.raw, [id.raw] as CFArray, [space.raw] as CFArray)
        CGSRemoveWindowsFromSpaces(connection.raw, [id.raw] as CFArray, [curSpace.raw] as CFArray)
    }

    public static func list(_ options: ListOptions = .all, excludeDesktopElements: Bool = false) throws -> [Window] {
        var (rawOptions, windowID) = options.raw
        if excludeDesktopElements {
            rawOptions.formUnion(.excludeDesktopElements)
        }
        guard let arr = CGWindowListCopyWindowInfo(rawOptions, windowID) as? [[String: Any]] else {
            throw Error.listingFailed
        }
        return try arr.map(Window.init(rawDescriptor:))
    }
}
