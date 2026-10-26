import Foundation
import Logging

private let log = Logger(imessageLabel: "best-window-coordinator")

func getBestWindowCoordinator() throws -> any WindowCoordinator {
    if let specified = Defaults.imessage.string(forKey: DefaultsKeys.coordinator) {
        switch specified {
        case "bridged-spaces": return try BridgedSpacesWindowCoordinator()
        case "spaces": return try SpacesWindowCoordinator()
        default: log.warning("unknown forced coordinator, using OS default")
        }
    }

    if #available(macOS 15, *) {
        return try BridgedSpacesWindowCoordinator()
    }
    return try SpacesWindowCoordinator()
}
