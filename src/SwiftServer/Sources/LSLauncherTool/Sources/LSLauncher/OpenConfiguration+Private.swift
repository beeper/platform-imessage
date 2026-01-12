import Foundation
import AppKit

extension NSWorkspace.OpenConfiguration {

    // MARK: - Private Selectors and Keys

    public enum PrivateSelectors {
        public static let getAdditionalOptions = Selector(("_additionalLSOpenOptions"))
        public static let setAdditionalOptions = Selector(("_setAdditionalLSOpenOptions:"))

        // Launch behavior keys
        public static let kBackgroundLaunchKey = "_kLSOpenOptionBackgroundLaunchKey"
        public static let kLaunchIsUserActionKey = "_kLSOpenOptionLaunchIsUserActionKey"
        public static let kForegroundLaunchKey = "_kLSOpenOptionForegroundLaunchKey"
        public static let kUIElementLaunchKey = "_kLSOpenOptionUIElementLaunchKey"

        // UI control keys
        public static let kAllowLoginUIKey = "_kLSOpenOptionAllowLoginUIKey"
        public static let kAllowErrorUIKey = "_kLSOpenOptionAllowErrorUIKey"
        public static let kAllowConflictResolutionUIKey = "_kLSOpenOptionAllowConflictResolutionUIKey"
        public static let kHideKey = "_kLSOpenOptionHideKey"
        public static let kHideOthersKey = "_kLSOpenOptionHideOthersKey"
        public static let kActivateKey = "_kLSOpenOptionActivateKey"

        // Behavior control keys
        public static let kPrintDocumentsKey = "_kLSOpenOptionPrintDocumentsKey"
        public static let kPreferRunningInstanceKey = "_kLSOpenOptionPreferRunningInstanceKey"
        public static let kEnableURLOverridesKey = "_kLSOpenOptionEnableURLOverridesKey"
        public static let kRequiresUniversalLinksKey = "_kLSOpenOptionRequiresUniversalLinksKey"
        public static let kLaunchedByPersistenceKey = "_kLSOpenOptionLaunchedByPersistenceKey"
        public static let kStopProcessKey = "_kLSOpenOptionStopProcessKey"
        public static let kAddToRecentsKey = "_kLSOpenOptionAddToRecentsKey"

        // Process control keys
        public static let kWaitForApplicationToCheckInKey = "_kLSOpenOptionWaitForApplicationToCheckInKey"
        public static let kLaunchWhenThisProcessExitsKey = "_kLSOpenOptionLaunchWhenThisProcessExitsKey"
        public static let kNotRelaunchedForTALKey = "_kLSOpenOptionNotRelaunchedForTALKey"
        public static let kLaunchOutOfProcessKey = "_kLSOpenOptionLaunchOutOfProcessKey"

        // Security and sandbox keys
        public static let kAllowUnsignedExecutableKey = "_kLSOpenOptionAllowUnsignedExecutableKey"
        public static let kProhitLaunchingSelfKey = "__kLSOpenOptionProhitLaunchingSelfKey"
        public static let kDoNotAddSandboxAnnotationsKey = "_kLSOpenOptionDoNotAddSandboxAnnotationsKey"
        public static let kLaunchRequireBundledExecutableKey = "_kLSLaunchRequireBundledExecutableKey"

        // State and synchronization keys
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

    // MARK: - Private Option Access

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

    /// Apply only keys present in the dictionary. Keys not present are left unset.
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

    // MARK: - UI Control Options

    /// Allow login UI to be shown if needed
    public var allowLoginUI: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAllowLoginUIKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAllowLoginUIKey) }
    }

    /// Allow error UI to be shown
    public var allowErrorUI: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAllowErrorUIKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAllowErrorUIKey) }
    }

    /// Allow conflict resolution UI
    public var allowConflictResolutionUI: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAllowConflictResolutionUIKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAllowConflictResolutionUIKey) }
    }

    /// Print documents after opening
    public var printDocuments: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kPrintDocumentsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kPrintDocumentsKey) }
    }

    /// Prefer an already running instance of the application
    public var preferRunningInstance: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kPreferRunningInstanceKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kPreferRunningInstanceKey) }
    }

    /// Enable URL overrides
    public var enableURLOverrides: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kEnableURLOverridesKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kEnableURLOverridesKey) }
    }

    /// Require universal links
    public var requiresUniversalLinks: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kRequiresUniversalLinksKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kRequiresUniversalLinksKey) }
    }

    /// Indicates the app was launched by persistence (login items)
    public var launchedByPersistence: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchedByPersistenceKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchedByPersistenceKey) }
    }

    // MARK: - Visibility Options

    /// Hide the application after launch
    public var lsHide: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kHideKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kHideKey) }
    }

    /// Hide other applications when launching
    public var lsHideOthers: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kHideOthersKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kHideOthersKey) }
    }

    /// Activate the application after launch
    public var lsActivate: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kActivateKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kActivateKey) }
    }

    /// Stop the process
    public var lsStopProcess: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kStopProcessKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kStopProcessKey) }
    }

    /// Add to recent documents
    public var addToRecents: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAddToRecentsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAddToRecentsKey) }
    }

    // MARK: - Launch Mode Options

    /// Launch in background mode (no dock icon, no UI)
    public var launchesInBackground: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kBackgroundLaunchKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kBackgroundLaunchKey) }
    }

    /// Launch as UIElement (no dock icon, but can have UI)
    public var uiElementLaunch: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kUIElementLaunchKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kUIElementLaunchKey) }
    }

    /// Launch in foreground (normal dock app)
    public var foregroundLaunch: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kForegroundLaunchKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kForegroundLaunchKey) }
    }

    // MARK: - Process Control Options

    /// Wait for the application to check in before returning
    public var waitForApplicationToCheckIn: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kWaitForApplicationToCheckInKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kWaitForApplicationToCheckInKey) }
    }

    /// Launch the application when this process exits
    public var launchWhenThisProcessExits: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchWhenThisProcessExitsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchWhenThisProcessExitsKey) }
    }

    /// Not relaunched for Terminated App List
    public var notRelaunchedForTAL: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kNotRelaunchedForTALKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kNotRelaunchedForTALKey) }
    }

    /// Launch out of process
    public var launchOutOfProcess: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchOutOfProcessKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchOutOfProcessKey) }
    }

    /// Indicates if the launch was a user action
    public var launchIsUserAction: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchIsUserActionKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchIsUserActionKey) }
    }

    // MARK: - Security Options

    /// Allow unsigned executable
    public var allowUnsignedExecutable: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAllowUnsignedExecutableKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAllowUnsignedExecutableKey) }
    }

    /// Prohibit launching self
    public var prohibitLaunchingSelf: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kProhitLaunchingSelfKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kProhitLaunchingSelfKey) }
    }

    /// Do not add sandbox annotations
    public var doNotAddSandboxAnnotations: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kDoNotAddSandboxAnnotationsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kDoNotAddSandboxAnnotationsKey) }
    }

    /// Require bundled executable
    public var requireBundledExecutable: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchRequireBundledExecutableKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchRequireBundledExecutableKey) }
    }

    // MARK: - State and Synchronization Options

    /// Launch without restoring previous state
    public var launchWithoutRestoringState: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kLaunchWithoutRestoringStateKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kLaunchWithoutRestoringStateKey) }
    }

    /// Open synchronously (block until app is ready)
    public var synchronousOpen: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kSynchronousKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kSynchronousKey) }
    }

    /// Include current environment values
    public var includeCurrentEnvironmentValues: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kIncludeCurrentEnvironmentValuesKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kIncludeCurrentEnvironmentValuesKey) }
    }

    /// Always open pasteboard contents
    public var alwaysOpenPasteboardContents: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kAlwaysOpenPasteboardContentsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kAlwaysOpenPasteboardContentsKey) }
    }

    /// Capture diagnostics
    public var captureDiagnostics: Bool? {
        get { getBoolOption(forKey: PrivateSelectors.kCaptureDiagnosticsKey) }
        set { setBoolOption(newValue, forKey: PrivateSelectors.kCaptureDiagnosticsKey) }
    }
}
