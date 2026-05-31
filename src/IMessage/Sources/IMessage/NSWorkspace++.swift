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

    var launchServicesAdditionalOptions: [String: Any] {
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

    func setLaunchServicesBoolOption(_ value: Bool?, forKey key: String) {
        var options = launchServicesAdditionalOptions
        if let value {
            options[key] = value
        } else {
            options.removeValue(forKey: key)
        }
        launchServicesAdditionalOptions = options
    }

    var launchesInBackground: Bool? {
        get { launchServicesAdditionalOptions[PrivateKeys.backgroundLaunch] as? Bool }
        set { setLaunchServicesBoolOption(newValue, forKey: PrivateKeys.backgroundLaunch) }
    }

    var launchIsUserAction: Bool? {
        get { launchServicesAdditionalOptions[PrivateKeys.launchIsUserAction] as? Bool }
        set { setLaunchServicesBoolOption(newValue, forKey: PrivateKeys.launchIsUserAction) }
    }

    var preferRunningInstance: Bool? {
        get { launchServicesAdditionalOptions[PrivateKeys.preferRunningInstance] as? Bool }
        set { setLaunchServicesBoolOption(newValue, forKey: PrivateKeys.preferRunningInstance) }
    }

    var launchWithoutRestoringState: Bool? {
        get { launchServicesAdditionalOptions[PrivateKeys.launchWithoutRestoringState] as? Bool }
        set { setLaunchServicesBoolOption(newValue, forKey: PrivateKeys.launchWithoutRestoringState) }
    }

    var waitForApplicationToCheckIn: Bool? {
        get { launchServicesAdditionalOptions[PrivateKeys.waitForApplicationToCheckIn] as? Bool }
        set { setLaunchServicesBoolOption(newValue, forKey: PrivateKeys.waitForApplicationToCheckIn) }
    }
}
