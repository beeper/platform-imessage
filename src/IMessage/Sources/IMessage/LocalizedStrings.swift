import Foundation

public enum LocalizedStrings {
    private static let chatKitFramework = Bundle(path: "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework")!
    private static let chatKitFrameworkAxBundle = Bundle(path: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle")!
    private static let notificationCenterApp = Bundle(path: "/System/Library/CoreServices/NotificationCenter.app")!

    public static let accessibilityPermissionLabel: String = {
        let fallback = "Accessibility"
        guard let privacySettings = Bundle(path: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex") else {
            return fallback
        }
        return strings(in: privacySettings, table: "Localizable", languages: systemSettingsLanguages, value: fallback)("ACCESSIBILITY")
    }()

    // Resolve in the languages of the app that shows the string, not this process's: the CLI/host
    // app may lack the user's language, and the user can set a per-app language.
    private static func languages(of bundleID: String) -> [String] {
        CFPreferencesCopyAppValue("AppleLanguages" as CFString, bundleID as CFString) as? [String] ?? Locale.preferredLanguages
    }

    private static let messagesLanguages = languages(of: messagesBundleID)
    private static let systemSettingsLanguages = languages(of: systemSettingsBundleID)

    private static func strings(in bundle: Bundle, table: String, languages: [String], value: String? = nil) -> (String) -> String {
        if #available(macOS 15.4, *) {
            let localizations = languages.map { Locale.Language(identifier: $0) }
            return { bundle.localizedString(forKey: $0, value: value, table: table, localizations: localizations) }
        }

        // Earlier Foundation versions need an explicit localization for both .loctable and .strings resources.
        let language = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: languages).first
        let translations = bundle.url(forResource: table, withExtension: "loctable")
            .flatMap { NSDictionary(contentsOf: $0) }?[language ?? ""] as? [String: Any]
        let localizedBundle = language.flatMap { bundle.url(forResource: $0, withExtension: "lproj") }.flatMap(Bundle.init(url:))
        return { key in
            loctableString(in: translations, key: key)
                ?? (localizedBundle ?? bundle).localizedString(forKey: key, value: value, table: table)
        }
    }

    /// Reads one entry of a loctable's per-language dictionary.
    static func loctableString(in translations: [String: Any]?, key: String) -> String? {
        let entry = translations?[key]
        // Some languages (e.g. ro, ca, sk) store a per-device variant dictionary instead of a string.
        let variants = (entry as? [String: Any])?["NSStringDeviceSpecificRuleType"] as? [String: Any]
        return entry as? String ?? variants?["mac"] as? String ?? variants?["other"] as? String
    }

    private static let chatString = strings(in: chatKitFramework, table: "ChatKit", languages: messagesLanguages)
    private static let accessibilityString = strings(in: chatKitFrameworkAxBundle, table: "Accessibility", languages: messagesLanguages)

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

    static let conversationUnread = accessibilityString("unread.messages")
    static let conversationMuted = accessibilityString("conversation.muted")
    static let conversationPinned = accessibilityString("pinned.label")
    static let conversationStates: Set = [conversationUnread, conversationMuted, conversationPinned]

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

    /// Title of the notifications pane in System Settings.
    static let notificationCenter = strings(in: notificationCenterApp, table: "Localizable", languages: systemSettingsLanguages)("Notification Center")

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
