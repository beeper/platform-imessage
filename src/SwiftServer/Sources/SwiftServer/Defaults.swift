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

enum Defaults {
    private static let dock = UserDefaults(suiteName: "com.apple.dock")
    private static let ncPrefs = UserDefaults(suiteName: "com.apple.ncprefs")

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
}
