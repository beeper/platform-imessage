import Foundation

public enum LocalizedStrings {
    private static let chatKitFramework = Bundle(path: "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework")!
    private static let chatKitFrameworkAxBundle = Bundle(path: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle")!
    private static let notificationCenterApp = Bundle(path: "/System/Library/CoreServices/NotificationCenter.app")!

    public static let accessibilityPermissionLabel: String = {
        let key = "ACCESSIBILITY", fallback = "Accessibility", table = "Localizable"
        guard let privacySettings = Bundle(path: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex") else {
            return fallback
        }
        if #available(macOS 15.4, *) {
            // A CLI or host app can support fewer languages than System Settings.
            return privacySettings.localizedString(forKey: key, value: fallback, table: table,
                                                  localizations: Locale.preferredLanguages.map { Locale.Language(identifier: $0) })
        }
        return privacySettings.localizedString(forKey: key, value: fallback, table: table)
    }()

    private static let messagesLanguages = CFPreferencesCopyValue(
        "AppleLanguages" as CFString, messagesBundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
    ) as? [String] ?? CFPreferencesCopyValue(
        "AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
    ) as? [String] ?? Locale.preferredLanguages

    private static func messagesStrings(in bundle: Bundle, table: String) -> (String) -> String {
        if #available(macOS 15.4, *) {
            let languages = messagesLanguages.map { Locale.Language(identifier: $0) }
            return { bundle.localizedString(forKey: $0, value: nil, table: table, localizations: languages) }
        }

        // Earlier Foundation versions need an explicit localization for both .loctable and .strings resources.
        let language = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: messagesLanguages).first
        let translations = bundle.url(forResource: table, withExtension: "loctable")
            .flatMap { NSDictionary(contentsOf: $0) }?[language ?? ""] as? [String: Any]
        let localizedBundle = language.flatMap { bundle.url(forResource: $0, withExtension: "lproj") }.flatMap(Bundle.init(url:))
        return { key in
            let entry = translations?[key]
            // Some languages (e.g. ro, ca, sk) store a per-device variant dictionary instead of a string.
            let variants = (entry as? [String: Any])?["NSStringDeviceSpecificRuleType"] as? [String: Any]
            return entry as? String ?? variants?["mac"] as? String ?? variants?["other"] as? String
                ?? (localizedBundle ?? bundle).localizedString(forKey: key, value: nil, table: table)
        }
    }

    private static let chatString = messagesStrings(in: chatKitFramework, table: "ChatKit")
    private static let accessibilityString = messagesStrings(in: chatKitFrameworkAxBundle, table: "Accessibility")

    static let imessage = chatString("MADRID")
    static let textMessage = chatString("TEXT_MESSAGE")
    // "Text Message • SMS" / "Text Message • RCS", macOS 15+; resolve to the raw key on older versions
    static let textMessageSMS = chatString("TEXT_MESSAGE_SMS")
    static let textMessageRCS = chatString("TEXT_MESSAGE_RCS")
    /// Placeholders of the message body field when the reply transcript isn't visible.
    static let composePlaceholders = [imessage, textMessage, textMessageSMS, textMessageRCS]

    static let markAsRead = chatString("MARK_AS_READ")
    static let markAsUnread = chatString("MARK_AS_UNREAD")
    static let delete = chatString("DELETE")
    static let pin = chatString("PIN")
    static let unpin = chatString("UNPIN")

    static let notificationsSilencedFormat = LocalizedNameFormat(chatString("UNAVAILABILITY_INDICATOR_TITLE_FORMAT"))
    static let notifyAnyway = chatString("NOTIFY_ANYWAY_BUTTON_TITLE")

    static let contactTyping = accessibilityString("contact.typing.message")
    static let contactWithNameTyping = accessibilityString("contact.typing.message.with.name")
    static let contactWithNameTypingFormat = LocalizedNameFormat(contactWithNameTyping)

    static let replyTranscript = accessibilityString("group.reply.collection")

    static let react = accessibilityString("acknowledgments.action.title")
    static let tapbackDetails = chatString("TAPBACK_DETAILS_ELLIPSIS")
    static let reactActionTitles = [react, tapbackDetails]
    static let reactionHeart = accessibilityString("acknowledgment.type.heart")
    static let reactionThumbsUp = accessibilityString("acknowledgment.type.thumbs.up")
    static let reactionThumbsDown = accessibilityString("acknowledgment.type.thumbs.down")
    static let reactionHa = accessibilityString("acknowledgment.type.ha")
    static let reactionExclamation = accessibilityString("acknowledgment.type.exclamation")
    static let reactionQuestionMark = accessibilityString("acknowledgment.type.question.mark")
    static let addEmojiTapback = chatString("ACCESSIBILITY_ADD_EMOJI_TAPBACK")
    static let reply = accessibilityString("balloon.message.reply")
    static let undoSend = chatString("UNDO_SEND_ACTION")

    /// "Send edit"
    static let editingConfirm = accessibilityString("editing.confirm.button")
    /// "Cancel edit"
    static let editingReject = accessibilityString("editing.reject.button")
    /// "Edit"
    static let editButton = accessibilityString("edit.button")

    static let notificationCenter = notificationCenterApp.localizedString(forKey: "Notification Center", value: nil, table: "Localizable")

    // "Dismiss"
    static let dismissButtonLabel = accessibilityString("dismiss.button.label")
    // "OK"
    static let ok = chatString("OK")

    // "Reply…"
    static let inlineReplyMenu = chatString("INLINE_REPLY_MENU")
}

/// Matches the literal text around a name in ChatKit's localized formats.
struct LocalizedNameFormat {
    private let prefix: String
    private let suffix: String

    init?(_ format: String) {
        // Thai loctables use the transliteration annotation instead of plain %@.
        let normalized = format.replacingOccurrences(of: "%[tt]@", with: "%@")
        let parts = normalized.components(separatedBy: "%@")
        guard parts.count == 2, !parts[0].isEmpty || !parts[1].isEmpty else { return nil }
        prefix = parts[0]
        suffix = parts[1]
    }

    func matches(_ label: String, allowingAttachmentPrefix: Bool = false) -> Bool {
        var text = label[...]
        // Focus AXStaticText descriptions may start with an attachment and a space.
        if allowingAttachmentPrefix, text.first == "\u{FFFC}" {
            text = text.dropFirst()
            if text.first == " " { text = text.dropFirst() }
        }
        guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { return false }
        return text.count > prefix.count + suffix.count
    }
}
