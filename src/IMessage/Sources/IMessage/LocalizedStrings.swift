import Foundation

public enum LocalizedStrings {
    private static let chatKitFramework = Bundle(path: "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework")!
    private static let chatKitFrameworkAxBundle = Bundle(path: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle")!
    private static let notificationCenterApp = Bundle(path: "/System/Library/CoreServices/NotificationCenter.app")!

    public static let accessibilityPermissionLabel: String = {
        guard let privacySettings = Bundle(path: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex") else {
            return "Accessibility"
        }
        if #available(macOS 15.4, *) {
            // A CLI or host app can support fewer languages than System Settings.
            return privacySettings.localizedString(forKey: "ACCESSIBILITY", value: "Accessibility", table: "Localizable",
                                                  localizations: Locale.preferredLanguages.map { Locale.Language(identifier: $0) })
        }
        return privacySettings.localizedString(forKey: "ACCESSIBILITY", value: "Accessibility", table: "Localizable")
    }()

    static let imessage = chatKitFramework.localizedString(forKey: "MADRID", value: nil, table: "ChatKit")
    static let textMessage = chatKitFramework.localizedString(forKey: "TEXT_MESSAGE", value: nil, table: "ChatKit")
    // "Text Message • SMS" / "Text Message • RCS", macOS 15+; resolve to the raw key on older versions
    static let textMessageSMS = chatKitFramework.localizedString(forKey: "TEXT_MESSAGE_SMS", value: nil, table: "ChatKit")
    static let textMessageRCS = chatKitFramework.localizedString(forKey: "TEXT_MESSAGE_RCS", value: nil, table: "ChatKit")
    /// Placeholders of the message body field when the reply transcript isn't visible.
    static let composePlaceholders = [imessage, textMessage, textMessageSMS, textMessageRCS]

    static let markAsRead = chatKitFramework.localizedString(forKey: "MARK_AS_READ", value: nil, table: "ChatKit")
    static let markAsUnread = chatKitFramework.localizedString(forKey: "MARK_AS_UNREAD", value: nil, table: "ChatKit")
    static let delete = chatKitFramework.localizedString(forKey: "DELETE", value: nil, table: "ChatKit")
    static let pin = chatKitFramework.localizedString(forKey: "PIN", value: nil, table: "ChatKit")
    static let unpin = chatKitFramework.localizedString(forKey: "UNPIN", value: nil, table: "ChatKit")

    static let notificationsSilencedFormat = LocalizedNameFormat(chatKitFramework.localizedString(forKey: "UNAVAILABILITY_INDICATOR_TITLE_FORMAT", value: nil, table: "ChatKit"))
    static let notifyAnyway = chatKitFramework.localizedString(forKey: "NOTIFY_ANYWAY_BUTTON_TITLE", value: nil, table: "ChatKit")

    static let contactTyping = chatKitFrameworkAxBundle.localizedString(forKey: "contact.typing.message", value: nil, table: "Accessibility")
    static let contactWithNameTyping = chatKitFrameworkAxBundle.localizedString(forKey: "contact.typing.message.with.name", value: nil, table: "Accessibility")
    static let contactWithNameTypingFormat = LocalizedNameFormat(contactWithNameTyping)

    static let replyTranscript = chatKitFrameworkAxBundle.localizedString(forKey: "group.reply.collection", value: nil, table: "Accessibility")

    static let react = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgments.action.title", value: nil, table: "Accessibility")
    static let tapbackDetails = chatKitFramework.localizedString(forKey: "TAPBACK_DETAILS_ELLIPSIS", value: nil, table: "ChatKit")
    static let reactActionTitles = [react, tapbackDetails]
    static let reactionHeart = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgment.type.heart", value: nil, table: "Accessibility")
    static let reactionThumbsUp = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgment.type.thumbs.up", value: nil, table: "Accessibility")
    static let reactionThumbsDown = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgment.type.thumbs.down", value: nil, table: "Accessibility")
    static let reactionHa = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgment.type.ha", value: nil, table: "Accessibility")
    static let reactionExclamation = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgment.type.exclamation", value: nil, table: "Accessibility")
    static let reactionQuestionMark = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgment.type.question.mark", value: nil, table: "Accessibility")
    static let addEmojiTapback = chatKitFramework.localizedString(forKey: "ACCESSIBILITY_ADD_EMOJI_TAPBACK", value: nil, table: "ChatKit")
    static let reply = chatKitFrameworkAxBundle.localizedString(forKey: "balloon.message.reply", value: nil, table: "Accessibility")
    static let undoSend = chatKitFramework.localizedString(forKey: "UNDO_SEND_ACTION", value: nil, table: "ChatKit")

    /// "Send edit"
    static let editingConfirm = chatKitFrameworkAxBundle.localizedString(forKey: "editing.confirm.button", value: nil, table: "Accessibility")
    /// "Cancel edit"
    static let editingReject = chatKitFrameworkAxBundle.localizedString(forKey: "editing.reject.button", value: nil, table: "Accessibility")
    /// "Edit"
    static let editButton = chatKitFrameworkAxBundle.localizedString(forKey: "edit.button", value: nil, table: "Accessibility")

    static let notificationCenter = notificationCenterApp.localizedString(forKey: "Notification Center", value: nil, table: "Localizable")

    // "Dismiss"
    static let dismissButtonLabel = chatKitFrameworkAxBundle.localizedString(forKey: "dismiss.button.label", value: nil, table: "Accessibility")
    // "OK"
    static let ok = chatKitFramework.localizedString(forKey: "OK", value: nil, table: "ChatKit")

    // "Reply…"
    static let inlineReplyMenu = chatKitFramework.localizedString(forKey: "INLINE_REPLY_MENU", value: nil, table: "ChatKit")
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
