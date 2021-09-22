import Foundation
import CWindowControl

public struct Space: Hashable {
    public enum Kind {
        case user
        case fullscreen
        case system

        var raw: CGSSpaceType {
            switch self {
            case .user: return CGSSpaceTypeUser
            case .fullscreen: return CGSSpaceTypeFullscreen
            case .system: return CGSSpaceTypeSystem
            }
        }
    }

    public static func active(for connection: GraphicsConnection = .main) throws -> Space {
        Space(raw: CGSGetActiveSpace(connection.raw))
    }

    public let raw: CGSSpaceID
    public init(raw: CGSSpaceID) {
        self.raw = raw
    }

    public init(newSpaceOfKind kind: Kind, display: Display = .main, connection: GraphicsConnection = .main) throws {
        raw = try CGSSpaceCreate(
            connection.raw, nil,
            [
                "type": kind.raw.rawValue as CFNumber,
                "uuid": display.uuid().uuidString
            ] as CFDictionary
        )
    }

    public func show(for connection: GraphicsConnection = .main) {
        CGSShowSpaces(connection.raw, [raw] as CFArray)
    }

    public func hide(for connection: GraphicsConnection = .main) {
        CGSHideSpaces(connection.raw, [raw] as CFArray)
    }
}
