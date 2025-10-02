import Foundation

public struct Message: Identifiable {
    public var id: Int
    public var guid: GUID<Message>

    // NOTE: This will often be `nil`, especially if there's an attributed body instead.
    public var text: Sensitive<String>?

    public var attributedBody: Sensitive<NSAttributedString>?

    // NOTE: The difference between these two are currently unknown.
    public var isFromMe: Bool
    public var isSent: Bool

    public var date: Date?
    public var dateRead: Date?
    public var dateDelivered: Date?

    public var attachments: [Attachment]?

    /** `message_summary_info` column */
    public var summaryInfo: SummaryInfo?
}
