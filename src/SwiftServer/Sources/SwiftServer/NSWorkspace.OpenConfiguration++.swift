import Foundation
import AppKit

// private launch option keys
private let kBackgroundLaunchKey = "_kLSOpenOptionBackgroundLaunchKey"
private let kLaunchIsUserActionKey = "_kLSOpenOptionLaunchIsUserActionKey"

extension NSWorkspace.OpenConfiguration {
    private struct PrivateSelectors {
        static let getAdditionalOptions = Selector(("_additionalLSOpenOptions"))
        static let setAdditionalOptions = Selector(("_setAdditionalLSOpenOptions:"))
    }
    
    private var additionalOptions: [String: Any] {
        get {
            guard responds(to: PrivateSelectors.getAdditionalOptions),
                  let result = perform(PrivateSelectors.getAdditionalOptions)?.takeUnretainedValue() as? [String: Any] else {
                return [:]
            }
            return result
        }
        set {
            guard responds(to: PrivateSelectors.setAdditionalOptions) else { return }
            perform(PrivateSelectors.setAdditionalOptions, with: newValue)
        }
    }
    
    private func withAdditionalOptions(_ mutate: (inout [String: Any]) -> Void) {
        print(additionalOptions)
        var opts = additionalOptions
        mutate(&opts)
        additionalOptions = opts
    }
    
    /// Wraps `_kLSOpenOptionBackgroundLaunchKey`
    var launchesInBackground: Bool {
        get {
            (additionalOptions[kBackgroundLaunchKey] as? Bool) ?? false
        }
        set {
            withAdditionalOptions { options in
                options[kBackgroundLaunchKey] = newValue
            }
        }
    }
    
    /// Wraps `_kLSOpenOptionLaunchIsUserActionKey`
    var launchIsUserAction: Bool {
        get {
            (additionalOptions[kLaunchIsUserActionKey] as? Bool) ?? false
        }
        set {
            withAdditionalOptions { options in
                options[kLaunchIsUserActionKey] = newValue
            }
        }
    }
}
