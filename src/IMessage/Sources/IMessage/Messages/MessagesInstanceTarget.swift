import AppKit
import Carbon.HIToolbox
import Foundation
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "messages-instance-target")

@available(macOS 11, *)
enum MessagesInstanceTarget {
    static func primaryInstance(in applications: [NSRunningApplication]) throws -> NSRunningApplication? {
        guard applications.count <= 1 else {
            throw ErrorMessage("Multiple Messages instances are running; use secondary-instance mode to avoid selecting another host's process")
        }
        return applications.first
    }

    private static func getURLAppleEvent(for url: URL, target: NSRunningApplication?) -> NSAppleEventDescriptor {
        let targetDescriptor: NSAppleEventDescriptor? = target.map { NSAppleEventDescriptor(processIdentifier: $0.processIdentifier) }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: targetDescriptor,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        event.setParam(
            NSAppleEventDescriptor(string: url.absoluteString),
            forKeyword: AEKeyword(keyDirectObject)
        )

        return event
    }

    static func sendDeepLink(
        _ url: URL,
        to app: NSRunningApplication,
        timeout: TimeInterval = 5
    ) throws {
        try getURLAppleEvent(for: url, target: app)
            .sendEvent(options: [.neverInteract, .noReply], timeout: timeout)
    }

    static func launchSecondaryInstance(
        initialDeepLink: URL? = nil,
        activating: Bool = false,
        hiding: Bool = false,
        timeout: TimeInterval = 8
    ) async throws -> NSRunningApplication {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID) else {
            throw ErrorMessage("Could not find Messages.app via LaunchServices")
        }
        let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).map(\.processIdentifier))

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activating
        configuration.hides = hiding || !activating
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        // A background-only launch leaves Messages unable to perform some AX actions even after its LaunchServices type changes.
        // Launch hidden as a normal UI process, then suppress its Dock presence before URLs.
        // configuration.launchesInBackground = !activating
        configuration.launchIsUserAction = activating
        configuration.preferRunningInstance = false
        configuration.launchWithoutRestoringState = true
        configuration.waitForApplicationToCheckIn = true

        let application = try await Task.withTimeout(timeout) {
            try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        }

        guard !existingPIDs.contains(application.processIdentifier) else {
            throw ErrorMessage("LaunchServices reused an existing Messages instance; refusing to suppress it")
        }
        var launchSucceeded = false
        defer { if !launchSucceeded { application.terminate() } }
        try await application.waitForLaunch(timeout: timeout)

        if !activating, Defaults.shouldSuppressMessagesDock {
            do {
                try MessagesDockSuppression.suppress(application)
            } catch {
                log.error("failed to hide secondary Messages from Dock: \(error)")
            }
        }

        if let initialDeepLink {
            try sendDeepLink(initialDeepLink, to: application)
        }

        if hiding {
            application.hide()
        }

        launchSucceeded = true
        return application
    }
}
