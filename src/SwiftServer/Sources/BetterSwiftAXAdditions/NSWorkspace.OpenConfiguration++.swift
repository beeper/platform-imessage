import Foundation
import AppKit

extension NSWorkspace.OpenConfiguration {
    public enum PrivateSelectors {
        public static let getAdditionalOptions = Selector(("_additionalLSOpenOptions"))
        public static let setAdditionalOptions = Selector(("_setAdditionalLSOpenOptions:"))
        
        // Known
        public static let kBackgroundLaunchKey = "_kLSOpenOptionBackgroundLaunchKey"
        public static let kLaunchIsUserActionKey = "_kLSOpenOptionLaunchIsUserActionKey"
        
        public static let kAllowLoginUIKey = "_kLSOpenOptionAllowLoginUIKey"
        public static let kAllowErrorUIKey = "_kLSOpenOptionAllowErrorUIKey"
        public static let kAllowConflictResolutionUIKey = "_kLSOpenOptionAllowConflictResolutionUIKey"
        public static let kPrintDocumentsKey = "_kLSOpenOptionPrintDocumentsKey"
        public static let kPreferRunningInstanceKey = "_kLSOpenOptionPreferRunningInstanceKey"
        public static let kEnableURLOverridesKey = "_kLSOpenOptionEnableURLOverridesKey"
        public static let kRequiresUniversalLinksKey = "_kLSOpenOptionRequiresUniversalLinksKey"
        public static let kLaunchedByPersistenceKey = "_kLSOpenOptionLaunchedByPersistenceKey"
        public static let kHideKey = "_kLSOpenOptionHideKey"
        public static let kHideOthersKey = "_kLSOpenOptionHideOthersKey"
        public static let kActivateKey = "_kLSOpenOptionActivateKey"
        public static let kStopProcessKey = "_kLSOpenOptionStopProcessKey"
        public static let kAddToRecentsKey = "_kLSOpenOptionAddToRecentsKey"
        public static let kUIElementLaunchKey = "_kLSOpenOptionUIElementLaunchKey"
        public static let kForegroundLaunchKey = "_kLSOpenOptionForegroundLaunchKey"
        public static let kWaitForApplicationToCheckInKey = "_kLSOpenOptionWaitForApplicationToCheckInKey"
        public static let kLaunchWhenThisProcessExitsKey = "_kLSOpenOptionLaunchWhenThisProcessExitsKey"
        public static let kNotRelaunchedForTALKey = "_kLSOpenOptionNotRelaunchedForTALKey"
        public static let kLaunchOutOfProcessKey = "_kLSOpenOptionLaunchOutOfProcessKey"
        public static let kAllowUnsignedExecutableKey = "_kLSOpenOptionAllowUnsignedExecutableKey"
        public static let kProhitLaunchingSelfKey = "__kLSOpenOptionProhitLaunchingSelfKey"
        public static let kDoNotAddSandboxAnnotationsKey = "_kLSOpenOptionDoNotAddSandboxAnnotationsKey"
        public static let kLaunchRequireBundledExecutableKey = "_kLSLaunchRequireBundledExecutableKey"
        public static let kLaunchWithoutRestoringStateKey = "_kLSOpenOptionLaunchWithoutRestoringStateKey"
        public static let kSynchronousKey = "_kLSOpenOptionSynchronousKey"
        public static let kIncludeCurrentEnvironmentValuesKey = "_kLSOpenOptionIncludeCurrentEnvironmentValuesKey"
        public static let kAlwaysOpenPasteboardContentsKey = "_kLSOpenOptionAlwaysOpenPasteboardContentsKey"
        public static let kCaptureDiagnosticsKey = "_kLSOpenOptionCaptureDiagnosticsKey"
        
        public static let allBoolKeys: [String] = [
            kAllowLoginUIKey,
            kAllowErrorUIKey,
            kAllowConflictResolutionUIKey,
            kPrintDocumentsKey,
            kPreferRunningInstanceKey,
            kEnableURLOverridesKey,
            kRequiresUniversalLinksKey,
            kLaunchedByPersistenceKey,
            kHideKey,
            kHideOthersKey,
            kActivateKey,
            kStopProcessKey,
            kAddToRecentsKey,
            kBackgroundLaunchKey,
            kUIElementLaunchKey,
            kForegroundLaunchKey,
            kWaitForApplicationToCheckInKey,
            kLaunchWhenThisProcessExitsKey,
            kNotRelaunchedForTALKey,
            kLaunchOutOfProcessKey,
            kLaunchIsUserActionKey,
            kAllowUnsignedExecutableKey,
            kProhitLaunchingSelfKey,
            kDoNotAddSandboxAnnotationsKey,
            kLaunchRequireBundledExecutableKey,
            kLaunchWithoutRestoringStateKey,
            kSynchronousKey,
            kIncludeCurrentEnvironmentValuesKey,
            kAlwaysOpenPasteboardContentsKey,
            kCaptureDiagnosticsKey
        ]
    }
    
    private var additionalOptions: [String: Any] {
        get {
            guard responds(to: PrivateSelectors.getAdditionalOptions),
                  let result = perform(PrivateSelectors.getAdditionalOptions)?
                .takeUnretainedValue() as? [String: Any]
            else {
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
        var options = additionalOptions
        mutate(&options)
        additionalOptions = options
    }
    
    private func getBoolOption(forKey key: String) -> Bool? {
        additionalOptions[key] as? Bool
    }
    
    private func setBoolOption(_ value: Bool?, forKey key: String) {
        withAdditionalOptions { options in
            if let value {
                options[key] = value
            } else {
                options.removeValue(forKey: key)
            }
        }
    }
    
    /// Apply only keys present in the dictionary. (Keys not present are left unset.)
    public func setPrivateBoolOptions(_ values: [String: Bool?]) {
        withAdditionalOptions { options in
            for (key, value) in values {
                if let value {
                    options[key] = value
                } else {
                    options.removeValue(forKey: key)
                }
            }
        }
    }
    
    // Typed wrappers now support nil/unset
    public var allowLoginUI: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAllowLoginUIKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAllowLoginUIKey) }
    }
    
    public var allowErrorUI: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAllowErrorUIKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAllowErrorUIKey) }
    }
    
    public var allowConflictResolutionUI: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAllowConflictResolutionUIKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAllowConflictResolutionUIKey) }
    }
    
    public var printDocuments: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kPrintDocumentsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kPrintDocumentsKey) }
    }
    
    public var preferRunningInstance: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kPreferRunningInstanceKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kPreferRunningInstanceKey) }
    }
    
    public var enableURLOverrides: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kEnableURLOverridesKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kEnableURLOverridesKey) }
    }
    
    public var requiresUniversalLinks: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kRequiresUniversalLinksKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kRequiresUniversalLinksKey) }
    }
    
    public var launchedByPersistence: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchedByPersistenceKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchedByPersistenceKey) }
    }
    
    public var lsHide: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kHideKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kHideKey) }
    }
    
    public var lsHideOthers: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kHideOthersKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kHideOthersKey) }
    }
    
    public var lsActivate: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kActivateKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kActivateKey) }
    }
    
    public var lsStopProcess: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kStopProcessKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kStopProcessKey) }
    }
    
    public var addToRecents: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAddToRecentsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAddToRecentsKey) }
    }
    
    public var launchesInBackground: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kBackgroundLaunchKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kBackgroundLaunchKey) }
    }
    
    public var uiElementLaunch: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kUIElementLaunchKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kUIElementLaunchKey) }
    }
    
    public var foregroundLaunch: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kForegroundLaunchKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kForegroundLaunchKey) }
    }
    
    public var waitForApplicationToCheckIn: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kWaitForApplicationToCheckInKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kWaitForApplicationToCheckInKey) }
    }
    
    public var launchWhenThisProcessExits: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchWhenThisProcessExitsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchWhenThisProcessExitsKey) }
    }
    
    public var notRelaunchedForTAL: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kNotRelaunchedForTALKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kNotRelaunchedForTALKey) }
    }
    
    public var launchOutOfProcess: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchOutOfProcessKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchOutOfProcessKey) }
    }
    
    public var launchIsUserAction: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchIsUserActionKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchIsUserActionKey) }
    }
    
    public var allowUnsignedExecutable: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAllowUnsignedExecutableKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAllowUnsignedExecutableKey) }
    }
    
    public var prohibitLaunchingSelf: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kProhitLaunchingSelfKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kProhitLaunchingSelfKey) }
    }
    
    public var doNotAddSandboxAnnotations: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kDoNotAddSandboxAnnotationsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kDoNotAddSandboxAnnotationsKey) }
    }
    
    public var requireBundledExecutable: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchRequireBundledExecutableKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchRequireBundledExecutableKey) }
    }
    
    public var launchWithoutRestoringState: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchWithoutRestoringStateKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchWithoutRestoringStateKey) }
    }
    
    public var synchronousOpen: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kSynchronousKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kSynchronousKey) }
    }
    
    public var includeCurrentEnvironmentValues: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kIncludeCurrentEnvironmentValuesKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kIncludeCurrentEnvironmentValuesKey) }
    }
    
    public var alwaysOpenPasteboardContents: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAlwaysOpenPasteboardContentsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAlwaysOpenPasteboardContentsKey) }
    }
    
    public var captureDiagnostics: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kCaptureDiagnosticsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kCaptureDiagnosticsKey) }
    }
}
