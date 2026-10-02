import Foundation

// main, pinning, ckDND are read protected on sonoma
private let pinningBundleID = "com.apple.messages.pinning"
private let dndBundleID = "com.apple.MobileSMS.CKDNDList"

private func randomCase(_ input: String) -> String {
    var result = ""
    for character in input {
        result += Bool.random()
            ? String(character).uppercased()
            : String(character)
    }
    if result == input { return randomCase(input) }
    return result
}

enum DefaultsKeys {
    /** controls whether window coordination happens at all, respected on the fly */
    static let windowCoordination = "BEEPWindowCoordination"
    /** forces a specific coordinator (`eclipsing` or `spaces`), only checked once */
    static let coordinator = "BEEPWindowCoordinator"

    /** whether to respect calls to `onThreadSelected` for thread activity observation */
    static let watchThreadActivity = "BEEPWatchThreadActivity"
    /** whether to continuously poll "activity status" (typing indicator, dnd banner) */
    static let pollActivityStatus = "BEEPPollActivityStatus"

    /** ensures that we've correctly selected threads before trying to interact with them */
    static let misfirePrevention = "BEEPMisfirePrevention"
    /** how misfire prevention verifies thread selection (`title-prediction`, `layout-waiter`, or `focus-waiter`) */
    static let misfirePreventionFallbackStrategy = "BEEPMisfirePreventionFallbackStrategy"
    /** if we don't want to use a real fallback strat, how long to sleep for */
    static let misfirePreventionSleepInterval = "BEEPMisfirePreventionSleepInterval"
    static let deepLinkTracingPII = "BEEPDeepLinkTracingPII"
    /** we try to use `IMCore` SPI for window title predictions for phone numbers */
    static let imCoreSPI = "BEEPIMCoreSPI"
    static let misfirePreventionTracing = "BEEPMisfirePreventionTracing"
    static let misfirePreventionTracingPII = "BEEPMisfirePreventionTracingPII"
    /** when predicting, whether we try to format contacts with the private short style */
    static let contactsAttemptFormattingWithShortStyle = "BEEPContactsAttemptFormattingWithShortStyle"
    /** whether to even attempt prediction for group chats. when `false`, assertions for group chats are skipped entirely */
    static let predictionPredictsGroupChats = "BEEPPredictionPredictsGroupChats"
    /** enables a hack to add a swapped prediction in the case of a group chat with two other people */
    static let predictionEnableSwapping = "BEEPPredictionEnableSwapping"

    /** try to inject menu item to open imessage settings UI */
    static let settingsMenuItemInjection = "BEEPSettingsMenuItemInjection"
    /** how long to maintain the menu item for, in seconds */
    static let settingsMenuItemInjectionMaintenancePeriod = "BEEPSettingsMenuItemInjectionMaintenancePeriod"
    /** how long to wait between maintenance checks, in seconds */
    static let settingsMenuItemInjectionMaintenanceInterval = "BEEPSettingsMenuItemInjectionMaintenanceInterval"
    /** name of menu item that lets the menu maintainer know that the app definitely isn't ready yet (`BeeperTexts`; Electron default) */
    static let settingsMenuItemInjectionDefinitelyNotReadyMenuItemTitle = "BEEPSettingsMenuItemInjectionDefinitelyNotReadyMenuItemTitle"
    /** locale case-insensitive substring to search for in menu titles; first result is injected into */
    static let settingsMenuItemInjectionTargetSubstring = "BEEPSettingsMenuItemInjectionTargetSubstring"

    // dimensions to resize the messages app window to
    static let eclipsingWidth = "BEEPEclipsingWidth"
    static let eclipsingHeight = "BEEPEclipsingHeight"
    /** class name prefix of the window that we base the eclipsing position of (the window that should be "in front") */
    static let eclipsingWindowClassNamePrefix = "BEEPEclipsingWindowClassNamePrefix"
    static let eclipsingUsesLargestWindow = "BEEPEclipsingUsesLargestWindow"
    /** only run eclipsing behavior if the "in front" window is large enough to accomodate the entirety of the window being hidden */
    static let onlyEclipseIfEncompasses = "BEEPOnlyEclipseIfEncompasses"
    static let eclipsingOffsetX = "BEEPEclipsingOffsetX"
    static let eclipsingOffsetY = "BEEPEclipsingOffsetY"
    static let eclipsingAlignment = "BEEPEclipsingAlignment"
    static let eclipsingDebug = "BEEPEclipsingDebug"
    static let eclipsingDebugVisualizationFadeOutDelay = "BEEPEclipsingDebugVisualizationFadeOutDelay"
    static let eclipsingDebugVisualizationFadeOutDuration = "BEEPEclipsingDebugVisualizationFadeOutDuration"
    /** (only used with `eclipsing`) debouncing period for hiding the messages app when we don't need it "onscreen" anymore */
    static let hidingCoordinatorDebounce = "BEEPHidingCoordinatorDebounce"

    /** always use `.unknown` space instead of `.user` */
    static let spacesAlwaysUseUnknownSpace = "BEEPSpacesAlwaysUseUnknownSpace"
    /** destroys the hidden space on `SpacesWindowCoordinator` being deinitialized */
    static let spacesDestroySpaceOnDeinit = "BEEPSpacesDestroySpaceOnDeinit"
    /** when a `.user` space is at play, recreate the hidden space when the dock relaunches */
    static let spacesObserveDock = "BEEPSpacesObserveDock"
    /** when a `.user` space is at play, move the window to the hidden space when the app is activated shortly after the space changes (our heuristic for the app being manually activated) */
    static let spacesObserveCurrentSpaceChanges = "BEEPSpacesObserveCurrentSpaceChanges"

    static let editingDelayBeforePressingMenuItem = "BEEPEditingDelayBeforePressingMenuItem"
    static let editingDelayBeforeReplacing = "BEEPEditingDelayBeforeReplacing"
    static let editingDelayBeforeFocusing = "BEEPEditingDelayBeforeFocusing"
    /** force all sends through the regular UI automation path instead of the OSA shortcut */
    static let disableOSAFastPath = "BEEPDisableOSAFastPath"

    static let eventWatcherTraceUnreads = "BEEPEventWatcherTraceUnreads"
    // debugging for FSEvents, waking up when the iMessage SQLite file changes, etc.
    static let eventWatcherTraceChangeListening = "BEEPEventWatcherTraceChangeListening"
    static let eventWatcherTraceMessageUpdates = "BEEPEventWatcherTraceMessageUpdates"
    static let hashingDangerouslyLeakPII = "BEEPHashingDangerouslyLeakPII"
}

// TODO: cleanup
@dynamicMemberLookup
enum Defaults {
    // Suite name kept as "swift-server" to preserve users' existing prefs
    // after the package rename — changing it would orphan their stored values.
    public static let imessage = UserDefaults(suiteName: "com.automattic.beeper.desktop.swift-server")!
    private static let ncPrefs = UserDefaults(suiteName: "com.apple.ncprefs")

    static func registerDefaults() {
        var defaults: [String: Any] = [
            DefaultsKeys.windowCoordination: true,

            DefaultsKeys.watchThreadActivity: true,
            DefaultsKeys.pollActivityStatus: true,

            DefaultsKeys.misfirePrevention: true,
            DefaultsKeys.misfirePreventionFallbackStrategy: "focus-waiter",
            // 0.3 (300ms) might be faster, but let's be conservative
            DefaultsKeys.misfirePreventionSleepInterval: 0.5,
            DefaultsKeys.imCoreSPI: true,
            DefaultsKeys.contactsAttemptFormattingWithShortStyle: true,
            DefaultsKeys.predictionPredictsGroupChats: true,
            DefaultsKeys.predictionEnableSwapping: true,

            // not injecting settings menu item anymore in favor of the secret
            // command bar item added to desktop
            DefaultsKeys.settingsMenuItemInjectionMaintenancePeriod: 15,
            DefaultsKeys.settingsMenuItemInjectionMaintenanceInterval: 1,
            DefaultsKeys.settingsMenuItemInjectionDefinitelyNotReadyMenuItemTitle: "BeeperTexts",
            DefaultsKeys.settingsMenuItemInjectionTargetSubstring: "Beeper",

            // Messages.app minimum size when resizing with mouse
            DefaultsKeys.eclipsingWidth: 660.0,
            DefaultsKeys.eclipsingHeight: 320.0,
            DefaultsKeys.eclipsingWindowClassNamePrefix: "Electron",
            DefaultsKeys.eclipsingUsesLargestWindow: true,
            DefaultsKeys.onlyEclipseIfEncompasses: true,
            DefaultsKeys.eclipsingAlignment: "right",
            DefaultsKeys.eclipsingOffsetX: 0.0,
            // positive values nudge the Messages window downwards
            // if set to 0.0, doesn't seem to be flush? are we targeting the right thing?
            DefaultsKeys.eclipsingOffsetY: 200.0,
            DefaultsKeys.eclipsingDebugVisualizationFadeOutDelay: 2,
            DefaultsKeys.eclipsingDebugVisualizationFadeOutDuration: 0.35,

            DefaultsKeys.hidingCoordinatorDebounce: 0.75,

            DefaultsKeys.spacesDestroySpaceOnDeinit: true,
            DefaultsKeys.spacesObserveDock: true,
            DefaultsKeys.spacesObserveCurrentSpaceChanges: true,

            DefaultsKeys.editingDelayBeforeReplacing: 0.5,
            DefaultsKeys.disableOSAFastPath: false,

            DefaultsKeys.eventWatcherTraceUnreads: true,
        ]

        #if DEBUG
        defaults[DefaultsKeys.eventWatcherTraceUnreads] = true
        defaults[DefaultsKeys.eventWatcherTraceMessageUpdates] = true
        #endif

        imessage.register(defaults: defaults)
    }

    static var shouldCoordinateWindow: Bool { Self.imessage.bool(forKey: DefaultsKeys.windowCoordination) }

    static func resetPrompts() {
        // getUserDefaults(bundleID: messagesBundleID)?.set(true, forKey: "kHasSetupHashtagImages") // unknown
        getUserDefaults(bundleID: messagesBundleID)?.set(true, forKey: "SMSRelaySettingsConfirmed") // unknown
        getUserDefaults(bundleID: messagesBundleID)?.set(true, forKey: "ReadReceiptSettingsConfirmed") // shown to confirm read receipts settings
        getUserDefaults(bundleID: messagesBundleID)?.set(2, forKey: "BusinessChatPrivacyPageDisplayed") // shown when a biz chat is selected for the first time
    }

    private static func getUserDefaults(bundleID: String) -> UserDefaults? {
        if #available(macOS 14, *) {
            let randomCasedBundleID = randomCase(bundleID)
            // these are prob non-deterministic no-ops
            for id in [bundleID, randomCasedBundleID] {
                UserDefaults(suiteName: id)?.synchronize()
                CFPreferencesAppSynchronize(id as CFString)
            }
            return UserDefaults(suiteName: randomCasedBundleID)
        }
        return UserDefaults(suiteName: bundleID)
    }

    static func isSelectedThreadCellPinned() -> Bool {
        getUserDefaults(bundleID: messagesBundleID)?.string(forKey: "CKLastSelectedItemIdentifier")?.hasPrefix("pinned-") == true
    }

    static var playSoundEffects: Bool {
        get {
            getUserDefaults(bundleID: messagesBundleID)?.bool(forKey: "PlaySoundsKey") ?? false
        }
        set {
            getUserDefaults(bundleID: messagesBundleID)?.set(newValue, forKey: "PlaySoundsKey")
        }
    }

    static func pinnedThreads() -> [String]? {
        getUserDefaults(bundleID: pinningBundleID)?.dictionary(forKey: "pD")?["pP"] as? [String]
    }

    static func pinnedThreadsCount() -> Int? {
        pinnedThreads()?.count
    }

    static func isNotificationsEnabledForApp(bundleID: String) -> Bool {
        guard let apps = ncPrefs?.array(forKey: "apps") as? [[String: Any]],
              let app = apps.first(where: { ($0["bundle-id"] as? String) == bundleID }),
              let flags = app["flags"] as? Int else {
            return false
        }
        // 25th bit is the notifications enabled bit
        return (flags >> 25) & 1 == 1
    }

    static func getDNDList() -> [String: Int]? {
        /*
         {
         CatalystDNDMigrationVersion: 2,
         CKDNDMigrationKey: 2,
         CKDNDListKey: {
         'hi@kishan.info': 64092211200,
         // chat.group_id
         '2B4EFF7E-3F26-4251-8902-F7062096CCCC: 64092211200,
         '+15551231234': 64092211200
         }
         }
         */
        guard let dict = getUserDefaults(bundleID: dndBundleID)?.dictionary(forKey: "CKDNDListKey") else {
            return nil
        }
        return dict as? [String: Int]
    }
}

extension Defaults {
    @inline(__always)
    static subscript(dynamicMember keyPath: KeyPath<DefaultsKeys.Type, String>) -> Bool {
        Defaults.imessage.bool(forKey: DefaultsKeys.self[keyPath: keyPath])
    }
}
