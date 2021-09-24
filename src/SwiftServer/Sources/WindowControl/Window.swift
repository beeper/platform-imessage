import Foundation
import CWindowControl

public struct Window: Hashable {
    public enum Error: Swift.Error {
        case listingFailed
        case windowNotFound
        case windowOnMultipleSpaces
        case missingKey(String)
        case invalidValue(key: String)
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
        case onScreenAbove(Window, orEqual: Bool)
        case onScreenBelow(Window, orEqual: Bool)

        var raw: (CGWindowListOption, CGWindowID) {
            switch self {
            case .all:
                return (.optionAll, kCGNullWindowID)
            case .onScreen:
                return (.optionOnScreenOnly, kCGNullWindowID)
            case let .onScreenAbove(window, orEqual):
                return (.optionOnScreenAboveWindow.union(orEqual ? .optionIncludingWindow : []), window.raw)
            case let .onScreenBelow(window, orEqual):
                return (.optionOnScreenBelowWindow.union(orEqual ? .optionIncludingWindow : []), window.raw)
            }
        }
    }

    public struct Description {
        public let window: Window
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

        public init(rawDescriptor: [String: Any]) throws {
            func get<T>(_ key: CFString, _ type: T.Type) throws -> T {
                try (rawDescriptor[key as String] as? T)
                    .orThrow(Error.missingKey(key as String))
            }

            let rawID = try get(kCGWindowNumber, CGWindowID.self)
            self.window = Window(raw: rawID)

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
    }

    public let raw: CGWindowID

    private static var connection = CGSMainConnectionID()

    public init(raw: CGWindowID) {
        self.raw = raw
    }

    // only works for our own windows?
    public func setAlpha(_ alpha: CGFloat, for connection: GraphicsConnection = .main) throws {
        if alpha < 1 {
            try GraphicsConnection.check(CGSSetWindowOpacity(connection.raw, raw, false))
        }
        try GraphicsConnection.check(CGSSetWindowAlpha(connection.raw, raw, alpha))
    }

    public func currentSpaces(_ options: Space.ListOptions, for connection: GraphicsConnection = .main) throws -> [Space] {
        guard let rawSpaces = CGSCopySpacesForWindows(connection.raw, options.raw, [raw] as CFArray)?
                .takeRetainedValue() as? [CGSSpaceID]
        else { throw Error.windowNotFound }
        return rawSpaces.map { Space(raw: $0) }
    }

    public func move(from spaces: [Space], to second: Space, for connection: GraphicsConnection = .main) throws {
        print("Move from \(spaces.map(\.raw)) to \(second.raw)")
        guard spaces.count != 1 || spaces[0] != second else { return } // no-op
        CGSAddWindowsToSpaces(connection.raw, [raw] as CFArray, [second.raw] as CFArray)
        CGSRemoveWindowsFromSpaces(connection.raw, [raw] as CFArray, spaces.map(\.raw) as CFArray)
    }

    public func moveToSpace(_ space: Space, for connection: GraphicsConnection = .main) throws {
        let curr = try currentSpaces(.allSpaces, for: connection)
        try move(from: curr, to: space, for: connection)
    }

    public func describe() throws -> Description {
        try Self.listDescriptions().first { $0.window == self }.orThrow(Error.windowNotFound)
//        guard let array = CGWindowListCreateDescriptionFromArray([raw] as CFArray) as? [[String: Any]],
//              array.count == 1 else { throw Error.windowNotFound }
//        let desc = try Description(rawDescriptor: array[0])
//        // this should always be true since we asked for exactly one window and got
//        // one back, but it's an extra sanity check
//        guard desc.window.raw == raw else { throw Error.windowNotFound }
//        return desc
    }

    public static func list(_ options: ListOptions = .all, excludeDesktopElements: Bool = false) throws -> [Window] {
        var (rawOptions, windowID) = options.raw
        if excludeDesktopElements {
            rawOptions.formUnion(.excludeDesktopElements)
        }
        guard let arr = TXTWindowListCreate(rawOptions, windowID).takeRetainedValue() as? [CGWindowID] else {
            throw Error.listingFailed
        }
        return arr.map(Self.init(raw:))
    }

    public static func listDescriptions(
        _ options: ListOptions = .all,
        excludeDesktopElements: Bool = false
    ) throws -> [Window.Description] {
        var (rawOptions, windowID) = options.raw
        if excludeDesktopElements {
            rawOptions.formUnion(.excludeDesktopElements)
        }
        guard let arr = CGWindowListCopyWindowInfo(rawOptions, windowID) as? [[String: Any]] else {
            throw Error.listingFailed
        }
        return try arr.map(Window.Description.init(rawDescriptor:))
    }
}
