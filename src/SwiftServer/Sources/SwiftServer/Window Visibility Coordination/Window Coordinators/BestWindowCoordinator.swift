import Foundation

func getBestWindowCoordinator() throws -> any WindowCoordinator {
    if ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0)) {
        EclipsingWindowCoordinator()
    } else {
        try SpacesWindowCoordinator()
    }
}
