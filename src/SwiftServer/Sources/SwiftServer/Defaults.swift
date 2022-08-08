import Foundation

enum Defaults {
    private static let main = UserDefaults(suiteName: messagesBundleID)
    private static let pinning = UserDefaults(suiteName: "com.apple.messages.pinning")

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

    static func pinnedThreads() -> [String]? {
        Defaults.pinning?.dictionary(forKey: "pD")?["pP"] as? [String]
    }

    static func pinnedThreadsCount() -> Int? {
        pinnedThreads()?.count
    }
}
