import AppKit
import AccessibilityControl
import Carbon.HIToolbox
import Foundation
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "messages-instance-target")

@available(macOS 11, *)
enum MessagesInstanceTarget {
    /// AppKit's cached isActive can lag activation during automation completion.
    /// Query the target through AX first so manual control prevents re-parking
    /// or Dock suppression; refresh AppKit state only as a fallback.
    static func isActive(_ app: NSRunningApplication) -> Bool {
        let frontmost = Accessibility.Attribute<Bool>.Name(kAXFrontmostAttribute)
        return (try? Accessibility.Element(pid: app.processIdentifier).attribute(frontmost)()) ??
            (NSRunningApplication(processIdentifier: app.processIdentifier)?.isActive == true)
    }

    static func primaryInstance(in applications: [NSRunningApplication]) throws -> NSRunningApplication? {
        let live = applications.filter { $0.processIdentifier > 0 && (kill($0.processIdentifier, 0) == 0 || errno != ESRCH) }
        guard live.count <= 1 else {
            throw ErrorMessage("Multiple Messages instances are running; use secondary-instance mode to avoid selecting another host's process")
        }
        return live.first
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
    ) throws -> NSRunningApplication {
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

        let waiter = DispatchSemaphore(value: 0)
        var result: Result<NSRunningApplication, Error>?

        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { app, error in
            if let error {
                result = .failure(error)
            } else if let app {
                result = .success(app)
            } else {
                result = .failure(ErrorMessage("LaunchServices completed without returning Messages.app"))
            }
            waiter.signal()
        }

        guard waiter.wait(timeout: .now() + timeout) == .success else {
            throw ErrorMessage("Timed out waiting for secondary Messages.app launch after \(timeout)s")
        }

        let app = try result.orThrow(ErrorMessage("Messages.app launch did not complete")).get()
        guard !existingPIDs.contains(app.processIdentifier) else {
            throw ErrorMessage("LaunchServices reused an existing Messages instance; refusing to suppress it")
        }
        var launchSucceeded = false
        defer {
            if !launchSucceeded {
                // Only this newly created process belongs to us.
                app.terminate()
            }
        }
        try app.waitForLaunch(timeout: timeout)

        if !activating, Defaults.shouldSuppressMessagesDock {
            do {
                try MessagesDockSuppression.suppress(app)
            } catch {
                log.error("failed to hide secondary Messages from Dock: \(error)")
            }
        }

        if let initialDeepLink {
            try sendDeepLink(initialDeepLink, to: app)
        }

        if hiding {
            app.hide()
        }

        launchSucceeded = true
        return app
    }
}
