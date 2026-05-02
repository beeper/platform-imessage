import Foundation
import AppKit

extension NSWorkspace.OpenConfiguration {
    enum PrivateKeys {
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
            guard responds(to: PrivateKeys.getAdditionalOptions),
                  let result = perform(PrivateKeys.getAdditionalOptions)?
                    .takeUnretainedValue() as? [String: Any]
            else {
                return [:]
            }
            return result
        }
        set {
            guard responds(to: PrivateKeys.setAdditionalOptions) else { return }
            perform(PrivateKeys.setAdditionalOptions, with: newValue)
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
        get { messagesInstanceAdditionalOptions[PrivateKeys.backgroundLaunch] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: PrivateKeys.backgroundLaunch) }
    }

    var messagesInstanceLaunchIsUserAction: Bool? {
        get { messagesInstanceAdditionalOptions[PrivateKeys.launchIsUserAction] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: PrivateKeys.launchIsUserAction) }
    }

    var messagesInstancePreferRunningInstance: Bool? {
        get { messagesInstanceAdditionalOptions[PrivateKeys.preferRunningInstance] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: PrivateKeys.preferRunningInstance) }
    }

    var messagesInstanceLaunchWithoutRestoringState: Bool? {
        get { messagesInstanceAdditionalOptions[PrivateKeys.launchWithoutRestoringState] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: PrivateKeys.launchWithoutRestoringState) }
    }

    var messagesInstanceWaitForApplicationToCheckIn: Bool? {
        get { messagesInstanceAdditionalOptions[PrivateKeys.waitForApplicationToCheckIn] as? Bool }
        set { setMessagesInstanceBoolOption(newValue, forKey: PrivateKeys.waitForApplicationToCheckIn) }
    }
}
