import Foundation
import Logging

private let log = Logger(swiftServerLabel: "best-window-coordinator")

func getBestWindowCoordinator() throws -> any WindowCoordinator {
    let specifiedCoordinator = Defaults.swiftServer.string(forKey: DefaultsKeys.coordinator)
    
    // FIXME: (@pmanot) - this is temporary, remove
    return EdgeWindowCoordinator()

    if let specifiedCoordinator {
        log.notice("coordinator overridden to \"\(specifiedCoordinator)\"")
        switch specifiedCoordinator {
        case "eclipsing": return EclipsingWindowCoordinator()
        case "spaces": return try SpacesWindowCoordinator()
        default: log.warning("unknown forced coordinator, determining as usual")
        }
    }

    if MacOSVersion.isAtLeast(.sequoia) {
        log.debug("detected macOS 15 or later, using eclipsing window coordinator")
        return EclipsingWindowCoordinator()
    } else {
        log.debug("using spaces window coordinator")
        return try SpacesWindowCoordinator()
    }
}
