import Foundation

public struct Message: Identifiable {
    public var id: Int
    public var guid: GUID<Message>

    // NOTE: This will often be `nil`, especially if there's an attributed body instead.
    public var text: Sensitive<String>?

    /**
     * NOTE: this is destructively modified when parts are edited or unsent
     */
    public var attributedBody: Sensitive<NSAttributedString>?

    // NOTE: The difference between these two are currently unknown.
    public var isFromMe: Bool
    public var isSent: Bool

    /** when the message was sent */
    public var date: Date?
    public var dateRead: Date?
    public var dateDelivered: Date?

    /** joined from another table; `nil` if this hasn't been done yet */
    public var attachments: [Attachment]?

    /** `message_summary_info` column */
    public var summaryInfo: SummaryInfo?
}
