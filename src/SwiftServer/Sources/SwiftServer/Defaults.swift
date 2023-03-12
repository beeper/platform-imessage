import Foundation

enum Defaults {
    private static let main = UserDefaults(suiteName: messagesBundleID)
    private static let pinning = UserDefaults(suiteName: "com.apple.messages.pinning")
    private static let dock = UserDefaults(suiteName: "com.apple.dock")
    private static let ncPrefs = UserDefaults(suiteName: "com.apple.ncprefs")

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

    static func isAppInDock(bundleID: String) -> Bool {
        guard let persistentApps = dock?.array(forKey: "persistent-apps") as? [[String: Any]] else {
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

    static func isNotificationsEnabledForApp(bundleID: String) -> Bool {
        guard let apps = ncPrefs?.array(forKey: "apps") as? [[String: Any]] else {
            return false
        }

        guard let app = apps.first(where: {$0["bundle-id"] as? String) == bundleID }) else {
            return false
        }

        guard let flags = app["flags"] as? Int else {
            return false
        }

        // 25th bit is the notifications enabled bit
        return (flags >> 25) & 1 == 1
    }
}
