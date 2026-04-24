import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftServerFoundation

enum MessagesInstanceMode: String {
    case `default`
    case puppet
}

extension Preferences {
    static var messagesInstanceModeValue: MessagesInstanceMode {
        MessagesInstanceMode(rawValue: messagesInstanceMode) ?? .default
    }
}

private extension NSWorkspace.OpenConfiguration {
    enum MessagesInstanceLSOption {
        static let getAdditionalOptions = Selector(("_additionalLSOpenOptions"))
        static let setAdditionalOptions = Selector(("_setAdditionalLSOpenOptions:"))

        static let backgroundLaunch = "_kLSOpenOptionBackgroundLaunchKey"
        static let launchIsUserAction = "_kLSOpenOptionLaunchIsUserActionKey"
        static let launchWithoutRestoringState = "_kLSOpenOptionLaunchWithoutRestoringStateKey"
        static let preferRunningInstance = "_kLSOpenOptionPreferRunningInstanceKey"
        static let waitForApplicationToCheckIn = "_kLSOpenOptionWaitForApplicationToCheckInKey"
    }

    var messagesInstanceAdditionalOptions: [String: Any] {
        get {
            guard responds(to: MessagesInstanceLSOption.getAdditionalOptions),
                  let result = perform(MessagesInstanceLSOption.getAdditionalOptions)?
                    .takeUnretainedValue() as? [String: Any]
            else {
                return [:]
            }
            return result
        }
        set {
            guard responds(to: MessagesInstanceLSOption.setAdditionalOptions) else { return }
            perform(MessagesInstanceLSOption.setAdditionalOptions, with: newValue)
        }
    }

    func setMessagesInstanceBoolOption(_ value: Bool?, forKey key: String) {
        var options = messagesInstanceAdditionalOptions
        if let value {
            options[key] = value
        } else {
            options.removeValue(forKey: key)
        }
        messagesInstanceAdditionalOptions = options
    }

    var messagesInstanceLaunchesInBackground: Bool? {
        get { messagesInstanceAdditionalOptions[MessagesInstanceLSOption.backgroundLaunch] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: MessagesInstanceLSOption.backgroundLaunch) }
    }

    var messagesInstanceLaunchIsUserAction: Bool? {
        get { messagesInstanceAdditionalOptions[MessagesInstanceLSOption.launchIsUserAction] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: MessagesInstanceLSOption.launchIsUserAction) }
    }

    var messagesInstancePreferRunningInstance: Bool? {
        get { messagesInstanceAdditionalOptions[MessagesInstanceLSOption.preferRunningInstance] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: MessagesInstanceLSOption.preferRunningInstance) }
    }

    var messagesInstanceLaunchWithoutRestoringState: Bool? {
        get { messagesInstanceAdditionalOptions[MessagesInstanceLSOption.launchWithoutRestoringState] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: MessagesInstanceLSOption.launchWithoutRestoringState) }
    }

    var messagesInstanceWaitForApplicationToCheckIn: Bool? {
        get { messagesInstanceAdditionalOptions[MessagesInstanceLSOption.waitForApplicationToCheckIn] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: MessagesInstanceLSOption.waitForApplicationToCheckIn) }
    }
}

@available(macOS 11, *)
enum MessagesInstanceTarget {
    static func getURLAppleEvent(for url: URL, target: NSRunningApplication?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: target.map { NSAppleEventDescriptor(processIdentifier: $0.processIdentifier) },
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

    static func launchPuppet(
        initialDeepLink: URL? = nil,
        activating: Bool = false,
        hiding: Bool = true,
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
        configuration.messagesInstanceLaunchesInBackground = true
        configuration.messagesInstanceLaunchIsUserAction = true
        configuration.messagesInstancePreferRunningInstance = false
        configuration.messagesInstanceLaunchWithoutRestoringState = true
        configuration.messagesInstanceWaitForApplicationToCheckIn = true

        if let initialDeepLink {
            configuration.appleEvent = getURLAppleEvent(for: initialDeepLink, target: nil)
        }

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
            throw ErrorMessage("Timed out waiting for puppet Messages.app launch after \(timeout)s")
        }

        let app = try result.orThrow(ErrorMessage("Messages.app launch did not complete")).get()
        try app.waitForLaunch(timeout: timeout)
        if hiding {
            app.hide()
        }
        return app
    }
}
