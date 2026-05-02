import AppKit
import Carbon.HIToolbox
import Foundation
import IMessageCore

@available(macOS 11, *)
enum MessagesInstanceTarget {
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

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activating
        configuration.hides = hiding
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.messagesInstanceLaunchIsUserAction = true
        configuration.messagesInstancePreferRunningInstance = false
        configuration.messagesInstanceLaunchWithoutRestoringState = true
        configuration.messagesInstanceWaitForApplicationToCheckIn = true

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
        try app.waitForLaunch(timeout: timeout)

        if let initialDeepLink {
            try sendDeepLink(initialDeepLink, to: app)
        }

        if hiding {
            app.hide()
        }

        return app
    }
}
