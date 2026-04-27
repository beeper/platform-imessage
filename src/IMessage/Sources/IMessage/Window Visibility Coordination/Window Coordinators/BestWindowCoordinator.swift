import Foundation
import Logging

private let log = Logger(imessageLabel: "best-window-coordinator")

func getBestWindowCoordinator() throws -> any WindowCoordinator {
    let specifiedCoordinator = Defaults.imessage.string(forKey: DefaultsKeys.coordinator)

    if let specifiedCoordinator {
        log.notice("coordinator overridden to \"\(specifiedCoordinator)\"")
        switch specifiedCoordinator {
        case "eclipsing": return EclipsingWindowCoordinator()
        case "spaces": return try SpacesWindowCoordinator()
        default: log.warning("unknown forced coordinator, determining as usual")
        }
    }

    let sequoiaOrLater = ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0))

    if sequoiaOrLater {
        log.debug("detected macOS 15 or later, using eclipsing window coordinator")
        return EclipsingWindowCoordinator()
    }
    log.debug("using spaces window coordinator")
    return try SpacesWindowCoordinator()
}
