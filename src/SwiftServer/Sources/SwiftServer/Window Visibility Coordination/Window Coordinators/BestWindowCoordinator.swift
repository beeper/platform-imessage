import Foundation
import Logging

private let log = Logger(swiftServerLabel: "best-window-coordinator")

@available(macOS 11, *)
func getBestWindowCoordinator() throws -> any WindowCoordinator {
    let specifiedCoordinator = Defaults.swiftServer.string(forKey: DefaultsKeys.coordinator)

    if let specifiedCoordinator, !specifiedCoordinator.isEmpty {
        log.notice("coordinator overridden to \"\(specifiedCoordinator)\"")
        switch specifiedCoordinator {
        case "eclipsing": return EclipsingWindowCoordinator()
        case "spaces": return SpacesWindowCoordinator()
        case "edge": return EdgeWindowCoordinator()
        case "puppet": return PuppetWindowCoordinator()
        default: log.warning("unknown forced coordinator, determining as usual")
        }
    }

    // When using puppet instance mode, use the PuppetWindowCoordinator by default
    if Defaults.useExperimentalPuppetInstance {
        log.debug("puppet instance mode enabled, using puppet window coordinator")
        return PuppetWindowCoordinator()
    }

    let sequoiaOrLater = ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0))

    if sequoiaOrLater {
        log.debug("detected macOS 15 or later, using eclipsing window coordinator")
        return EclipsingWindowCoordinator()
    } else {
        log.debug("using spaces window coordinator")
        return SpacesWindowCoordinator()
    }
}
