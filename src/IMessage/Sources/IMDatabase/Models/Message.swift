import Foundation

public struct Message: Identifiable {
    public var id: Int
    public var guid: GUID<Message>
    public var balloonBundleID: String?
    public var threadOriginatorGUID: GUID<Message>?

    // NOTE: This will often be `nil`, especially if there's an attributed body instead.
    public var text: Sensitive<String>?

    /**
     * NOTE: this is destructively modified when parts are edited or unsent
     */
    public var attributedBody: Sensitive<NSAttributedString>?

    // NOTE: The difference between these two are currently unknown.
    public var isFromMe: Bool
    public var isSent: Bool

    /** Raw `message.date` value from chat.db. Use for DB follow-up queries that need exact cursor semantics. */
    public var dateNanosecondsSinceReferenceDate: Int64?
    /** Raw `message.date_read` value from chat.db. */
    public var dateReadNanosecondsSinceReferenceDate: Int64?

    /** when the message was sent */
    public var date: Date? {
        dateNanosecondsSinceReferenceDate.flatMap(Date.init(imCoreNanosecondsSinceReferenceDate:))
    }
    public var dateRead: Date? {
        dateReadNanosecondsSinceReferenceDate.flatMap(Date.init(imCoreNanosecondsSinceReferenceDate:))
    }
    public var dateDelivered: Date?

    /** joined from another table; `nil` if this hasn't been done yet */
    public var attachments: [Attachment]?

    /** `message_summary_info` column */
    public var summaryInfo: SummaryInfo?
}
