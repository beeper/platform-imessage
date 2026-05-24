import Foundation

enum LocalizedStrings {
    private static let chatKitFramework = Bundle(path: "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework")!
    private static let chatKitFrameworkAxBundle = Bundle(path: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle")!
    private static let notificationCenterApp = Bundle(path: "/System/Library/CoreServices/NotificationCenter.app")!

    static let imessage = chatKitFramework.localizedString(forKey: "MADRID", value: nil, table: "ChatKit")
    static let textMessage = chatKitFramework.localizedString(forKey: "TEXT_MESSAGE", value: nil, table: "ChatKit")

    static let markAsRead = chatKitFramework.localizedString(forKey: "MARK_AS_READ", value: nil, table: "ChatKit")
    static let markAsUnread = chatKitFramework.localizedString(forKey: "MARK_AS_UNREAD", value: nil, table: "ChatKit")
    static let delete = chatKitFramework.localizedString(forKey: "DELETE", value: nil, table: "ChatKit")
    static let pin = chatKitFramework.localizedString(forKey: "PIN", value: nil, table: "ChatKit")
    static let unpin = chatKitFramework.localizedString(forKey: "UNPIN", value: nil, table: "ChatKit")

    static let hasNotificationsSilencedSuffix = chatKitFramework.localizedString(forKey: "UNAVAILABILITY_INDICATOR_TITLE_FORMAT", value: nil, table: "ChatKit").replacingOccurrences(of: "%@", with: "")
    static let notifyAnyway = chatKitFramework.localizedString(forKey: "NOTIFY_ANYWAY_BUTTON_TITLE", value: nil, table: "ChatKit")

    static let contactTyping = chatKitFrameworkAxBundle.localizedString(forKey: "contact.typing.message", value: nil, table: "Accessibility")
    static let contactWithNameTyping = chatKitFrameworkAxBundle.localizedString(forKey: "contact.typing.message.with.name", value: nil, table: "Accessibility")
    static let contactWithNameTypingSuffix = contactWithNameTyping.components(separatedBy: "%@").last ?? contactWithNameTyping

    static let replyTranscript = chatKitFrameworkAxBundle.localizedString(forKey: "group.reply.collection", value: nil, table: "Accessibility")

    static let showAlerts = chatKitFrameworkAxBundle.localizedString(forKey: "show.alerts.collection.view.cell", value: nil, table: "Accessibility")
    static let hideAlerts = chatKitFrameworkAxBundle.localizedString(forKey: "hide.alerts.collection.view.cell", value: nil, table: "Accessibility")

    static let react = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgments.action.title", value: nil, table: "Accessibility")
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

    // "OK"
    static let dismissButtonLabel = chatKitFrameworkAxBundle.localizedString(forKey: "dismiss.button.label", value: nil, table: nil)
    // "OK"
    static let ok = chatKitFramework.localizedString(forKey: "OK", value: nil, table: nil)

    // "Reply…"
    static let inlineReplyMenu = chatKitFramework.localizedString(forKey: "INLINE_REPLY_MENU", value: nil, table: "ChatKit")
}
