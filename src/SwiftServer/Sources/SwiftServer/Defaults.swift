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
    static let phtAllowInstallation = "BEEPPHTAllowInstallation"
    static let phtAllowConnection = "BEEPPHTAllowConnection"

    /** controls whether window coordination happens at all, respected on the fly */
    static let windowCoordination = "BEEPWindowCoordination"
    /** forces a specific coordinator (`eclipsing` or `spaces`), only checked once */
    static let coordinator = "BEEPWindowCoordinator"

    /** whether to respect calls to `onThreadSelected`/`watchThreadActivity` */
    static let watchThreadActivity = "BEEPWatchThreadActivity"
    /** whether to continuously poll "activity status" (typing indicator, dnd banner) */
    static let pollActivityStatus = "BEEPPollActivityStatus"

    /** ensures that we've correctly selected threads before trying to interact with them */
    static let misfirePrevention = "BEEPMisfirePrevention"
    /** when mobilesms defaults are blocked, whether we try to predict the window title in order to prevent misfires */
    static let prediction = "BEEPPrediction"
    /** we try to use `IMCore` SPI for window title predictions for phone numbers */
    static let imCoreSPI = "BEEPIMCoreSPI"
    static let misfirePreventionTracing = "BEEPMisfirePreventionTracing"
    /** whether to always attempt window title prediction, even if we have defaults access */
    static let misfirePreventionAlwaysPredict = "BEEPMisfirePreventionAlwaysPredict"
    static let misfirePreventionTracingPII = "BEEPMisfirePreventionTracingPII"
    /** when predicting, whether we try to format contacts with the private short style */
    static let contactsAttemptFormattingWithShortStyle = "BEEPContactsAttemptFormattingWithShortStyle"
    /** whether to even attempt prediction for group chats. when `false`, assertions for group chats are skipped entirely */
    static let predictionPredictsGroupChats = "BEEPPredictionPredictsGroupChats"
    /** enables a hack to add a swapped prediction in the case of a group chat with two other people */
    static let predictionEnableSwapping = "BEEPPredictionEnableSwapping"

    /** try to inject menu item to open swiftserver settings UI */
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
    /** always create a space of type .user */
    static let spacesAlwaysUseUserSpace = "BEEPSpacesAlwaysUseUserSpace"
    /** when a `.user` space is at play, recreate the hidden space when the dock relaunches */
    static let spacesObserveDock = "BEEPSpacesObserveDock"
    /** when a `.user` space is at play, move the window to the hidden space when the app is activated shortly after the space changes (our heuristic for the app being manually activated) */
    static let spacesObserveCurrentSpaceChanges = "BEEPSpacesObserveCurrentSpaceChanges"

    static let editingDelayBeforePressingMenuItem = "BEEPEditingDelayBeforePressingMenuItem"
    static let editingDelayBeforeReplacing = "BEEPEditingDelayBeforeReplacing"
    static let editingDelayBeforeFocusing = "BEEPEditingDelayBeforeFocusing"
    static let editingDelayPressingReturn = "BEEPEditingDelayBeforePressingReturn"

    static let pollerTraceUnreads = "BEEPPollerTraceUnreads"
    static let pollerTraceMessageUpdates = "BEEPPollerTraceMessageUpdates"
    static let hashingDangerouslyLeakPII = "BEEPHashingDangerouslyLeakPII"
}

// TODO: cleanup
enum Defaults {
    public static let swiftServer = UserDefaults(suiteName: "com.automattic.beeper.desktop.swift-server")!
    private static let dock = UserDefaults(suiteName: "com.apple.dock")
    private static let ncPrefs = UserDefaults(suiteName: "com.apple.ncprefs")

    static func registerDefaults() {
        var defaults: [String: Any] = [
            DefaultsKeys.phtAllowConnection: true,
            DefaultsKeys.phtAllowInstallation: true,

            DefaultsKeys.windowCoordination: true,

            DefaultsKeys.watchThreadActivity: true,
            DefaultsKeys.pollActivityStatus: true,

            DefaultsKeys.misfirePrevention: true,
            DefaultsKeys.prediction: true,
            DefaultsKeys.imCoreSPI: true,
            DefaultsKeys.contactsAttemptFormattingWithShortStyle: true,
            DefaultsKeys.predictionPredictsGroupChats: true,
            DefaultsKeys.predictionEnableSwapping: true,

            DefaultsKeys.settingsMenuItemInjection: true,
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
        ]

#if DEBUG
        defaults[DefaultsKeys.pollerTraceUnreads] = true
        defaults[DefaultsKeys.pollerTraceMessageUpdates] = true
#endif

        swiftServer.register(defaults: defaults)
    }

    static var shouldCoordinateWindow: Bool { Self.swiftServer.bool(forKey: DefaultsKeys.windowCoordination) }

    static func resetPrompts() {
        // getUserDefaults(bundleID: messagesBundleID)?.set(true, forKey: "kHasSetupHashtagImages") // unknown
        getUserDefaults(bundleID: messagesBundleID)?.set(true, forKey: "SMSRelaySettingsConfirmed") // unknown
        getUserDefaults(bundleID: messagesBundleID)?.set(true, forKey: "ReadReceiptSettingsConfirmed") // shown to confirm read receipts settings
        getUserDefaults(bundleID: messagesBundleID)?.set(2, forKey: "BusinessChatPrivacyPageDisplayed") // shown when a biz chat is selected for the first time
    }

    private static func getUserDefaults(bundleID: String) -> UserDefaultsProtocol? {
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

    static func getSelectedThreadID() -> String? {
        // CKLastSelectedItemIdentifier => "list-iMessage;-;hi@kishan.info"
        // CKLastSelectedItemIdentifier => "pinned-iMessage;-;hi@kishan.info"
        // CKLastSelectedItemIdentifier => CKConversationListNewMessageCellIdentifier
        getUserDefaults(bundleID: messagesBundleID)?.string(forKey: "CKLastSelectedItemIdentifier")?.split(separator: "-", maxSplits: 1).last.flatMap(String.init)
    }

    static func isSelectedThreadCellPinned() -> Bool {
        getUserDefaults(bundleID: messagesBundleID)?.string(forKey: "CKLastSelectedItemIdentifier")?.hasPrefix("pinned-") == true
    }

    static func isSelectedThreadCellCompose() -> Bool {
        getUserDefaults(bundleID: messagesBundleID)?.string(forKey: "CKLastSelectedItemIdentifier") == "CKConversationListNewMessageCellIdentifier"
    }

    static var playSoundEffects: Bool {
        get {
            getUserDefaults(bundleID: messagesBundleID)?.bool(forKey: "PlaySoundsKey") ?? false
        }
        set {
            getUserDefaults(bundleID: messagesBundleID)?.set(newValue, forKey: "PlaySoundsKey")
        }
    }

    #if DEBUG
    static func pinnedData() -> [String: Any]? {
        getUserDefaults(bundleID: pinningBundleID)?.dictionary(forKey: "pD")
    }

    static func changePinnedData(_ val: [String: Any]) {
        var modval = val
        modval["pT"] = NSDate()
        UserDefaults(suiteName: pinningBundleID)?.setValue(modval, forKey: "pD")
    }
    #endif

    static func pinnedThreads() -> [String]? {
        getUserDefaults(bundleID: pinningBundleID)?.dictionary(forKey: "pD")?["pP"] as? [String]
    }

    static func pinnedThreadsCount() -> Int? {
        pinnedThreads()?.count
    }

    // sync w desktop
    static func isAppInDock(bundleID: String) -> Bool {
        guard let dock, let persistentApps = dock.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return false
        }
        for app in persistentApps {
            if let td = app["tile-data"] as? [String: Any],
                let bi = td["bundle-identifier"] as? String,
                bundleID == bi {
                return true
            }
        }
        return false
    }

    // sync w desktop
    static func removeAppFromDock(bundleID: String) {
        guard let dock, var persistentApps = dock.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return
        }
        let appIndex = persistentApps.firstIndex { app in
            guard let tileData = app["tile-data"] as? [String: Any],
                let bundleIdentifier = tileData["bundle-identifier"] as? String else {
                return false
            }
            return bundleIdentifier == bundleID
        }
        guard let appIndex else {
            return
        }
        persistentApps.remove(at: appIndex)
        dock.set(persistentApps, forKey: "persistent-apps")
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

    static var misfirePreventionTracing: Bool {
        Defaults.swiftServer.bool(forKey: DefaultsKeys.misfirePreventionTracing)
    }

    static var misfirePreventionTracingPII: Bool {
        Defaults.swiftServer.bool(forKey: DefaultsKeys.misfirePreventionTracingPII)
    }
}
