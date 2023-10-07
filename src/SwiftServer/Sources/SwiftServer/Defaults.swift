import Foundation

// this will likely get patched soon
func fixForSonoma(_ str: String) -> String {
    isSonomaOrUp ? str.uppercased() : str
}
enum Defaults {
    private static let main = UserDefaults(suiteName: fixForSonoma(messagesBundleID))
    private static let pinning = UserDefaults(suiteName: fixForSonoma("com.apple.messages.pinning"))
    private static let dock = UserDefaults(suiteName: fixForSonoma("com.apple.dock"))
    private static let ncPrefs = UserDefaults(suiteName: fixForSonoma("com.apple.ncprefs"))

    static func resetPrompts() {
        // main?.set(true, forKey: "kHasSetupHashtagImages") // unknown
        main?.set(true, forKey: "SMSRelaySettingsConfirmed") // unknown
        main?.set(true, forKey: "ReadReceiptSettingsConfirmed") // shown to confirm read receipts settings
        main?.set(2, forKey: "BusinessChatPrivacyPageDisplayed") // shown when a biz chat is selected for the first time
    }

    static func getSelectedThreadID() -> String? {
        // CKLastSelectedItemIdentifier => "list-iMessage;-;hi@kishan.info"
        // CKLastSelectedItemIdentifier => "pinned-iMessage;-;hi@kishan.info"
        // CKLastSelectedItemIdentifier => CKConversationListNewMessageCellIdentifier
        main?.string(forKey: "CKLastSelectedItemIdentifier")?.split(separator: "-", maxSplits: 1).last.flatMap(String.init)
    }

    static func isSelectedThreadCellPinned() -> Bool {
        main?.string(forKey: "CKLastSelectedItemIdentifier")?.hasPrefix("pinned-") == true
    }

    static func isSelectedThreadCellCompose() -> Bool {
        main?.string(forKey: "CKLastSelectedItemIdentifier") == "CKConversationListNewMessageCellIdentifier"
    }

    static var playSoundEffects: Bool {
        get {
            main?.bool(forKey: "PlaySoundsKey") ?? false
        }
        set {
            main?.set(newValue, forKey: "PlaySoundsKey")
        }
    }

    #if DEBUG
    static func pinnedData() -> [String: Any]? {
        Defaults.pinning?.dictionary(forKey: "pD")
    }

    static func changePinnedData(_ val: [String: Any]) {
        var modval = val
        modval["pT"] = NSDate()
        Defaults.pinning?.setValue(modval, forKey: "pD")
    }
    #endif

    static func pinnedThreads() -> [String]? {
        Defaults.pinning?.dictionary(forKey: "pD")?["pP"] as? [String]
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
}
