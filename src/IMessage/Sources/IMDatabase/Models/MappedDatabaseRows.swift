import Foundation
import SQLiteData

/// Runtime counterparts to the historical TypeScript row shapes. Database
/// queries decode into these structs directly. Legacy fixture/original-payload
/// dictionary bridges live in MappedDatabaseRows+DictionaryBridges.swift.
///
/// Historical schema observations migrated from the old TypeScript raw row
/// types are preserved here as comments. These notes are checked against the
/// schema fixtures in `fixtures/`; a field can disappear across macOS releases,
/// so don't assume older observations are still present without comparing the
/// fixtures.
///
/// Message table columns were originally observed in `chat.db` on Big Sur and
/// extended as newer macOS releases added fields. Mapped columns carry their
/// notes inline below. Additional observed columns that are not currently
/// decoded by these mapped rows:
/// - `replace`: Observed by kb as `0` for all messages.
/// - `country`: Observed by kb as `NULL` for all messages.
/// - `version`: Observed by kb as `10` for all messages.
/// - `is_finished`: Observed by kb as `1` for all messages.
/// - `is_sent`: Slightly different from `is_from_me`.
/// - `is_forward`: Observed by kb as `0` for all messages.
/// - `is_archive`: Observed by kb as `0` for all messages.
/// - `date_played`: Prefer reading this through SQLite as text or converting in
///   Swift; JavaScript `number` frequently loses precision for Apple nanosecond
///   timestamps.
/// - `is_corrupt`: Observed by kb as `0` for all messages.
/// - `is_spam`: Observed by kb as `0` for all messages.
/// - `syndication_ranges`, `synced_syndication_ranges`,
///   `was_delivered_quietly`, `did_notify_recipient`: Added in Monterey.
/// - `part_count`: Added in Ventura.
/// - `is_stewie`: Added in Ventura 13.1.
/// - `is_sos`, `is_critical`, `bia_reference_id`: Observed in Tahoe.
/// - `is_kt_verified`: Added in Ventura 13.2 through 13.4.1.
/// - `fallback_hash`: Observed in Tahoe.
/// - `is_time_sensitive`, `ck_chat_id`, `index_state`: Observed in Tahoe.
///
/// Chat table columns were originally observed in `chat.db` on Big Sur and
/// extended as newer macOS releases added fields. Additional observed columns
/// that are not currently decoded by these mapped rows:
/// - `syndication_date`, `syndication_type`: Added in Monterey.
/// - `is_recovered`: Added in Ventura.
/// - `is_deleting_incoming_messages`, `is_pending_review`: Observed in Tahoe.

public protocol MappedDatabaseRow: QueryRepresentable where QueryOutput == Self {}

public extension MappedDatabaseRow where QueryOutput == Self {
    static func fetchAllMapped(
        _ db: Database,
        sql: String,
        arguments: [Any] = []
    ) throws -> [Self] {
        try fetchAllSQL(Self.self, db: db, sql: sql, arguments: arguments)
    }
}

public enum MappedDatabaseRowError: Error, CustomStringConvertible {
    case missingRequiredColumn(row: String, column: String)

    public var description: String {
        switch self {
        case let .missingRequiredColumn(row, column):
            return "Missing required \(row) column: \(column)"
        }
    }
}

@Selection
public struct MappedMessageRow: MappedDatabaseRow {
    @Column("ROWID")
    public let rowID: Int
    public let guid: String
    public let text: String?
    public let subject: String?
    public let attributedBody: Data?
    /// Usually "iMessage" or "SMS"; very old databases may contain other
    /// values from the iChat era.
    public let service: String?
    /// Numeric error code; `0` means success.
    @Column(as: ZeroDefaultIntRepresentation.self)
    public let error: Int
    /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
    /// needs to cross into JavaScript.
    public let date: Int?
    /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
    /// needs to cross into JavaScript.
    @Column("date_read")
    public let dateRead: Int?
    /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
    /// needs to cross into JavaScript.
    @Column("date_delivered")
    public let dateDelivered: Int?
    @Column("is_delivered", as: ZeroDefaultIntRepresentation.self)
    public let isDelivered: Int
    /// Slightly different from `is_sent`.
    @Column("is_from_me", as: ZeroDefaultIntRepresentation.self)
    public let isFromMe: Int
    @Column("is_read", as: ZeroDefaultIntRepresentation.self)
    public let isRead: Int
    @Column("is_audio_message", as: ZeroDefaultIntRepresentation.self)
    public let isAudioMessage: Int
    @Column("item_type", as: ZeroDefaultIntRepresentation.self)
    public let itemType: Int
    @Column("handle_id")
    public let handleID: Int?
    @Column("group_title")
    public let groupTitle: String?
    @Column("group_action_type", as: ZeroDefaultIntRepresentation.self)
    public let groupActionType: Int
    @Column("share_status", as: ZeroDefaultIntRepresentation.self)
    public let shareStatus: Int
    @Column("associated_message_guid")
    public let associatedMessageGUID: String?
    @Column("associated_message_type", as: ZeroDefaultIntRepresentation.self)
    public let associatedMessageType: Int
    /// Added in Sequoia.
    @Column("associated_message_emoji")
    public let associatedMessageEmoji: String?
    @Column("balloon_bundle_id")
    public let balloonBundleID: String?
    @Column("payload_data")
    public let payloadData: Data?
    @Column("expressive_send_style_id")
    public let expressiveSendStyleID: String?
    @Column("message_summary_info")
    public let messageSummaryInfo: Data?
    /// GUID of a related message. iMessage uses this for reaction removal rows
    /// to point back at the hidden reaction-add message row.
    @Column("reply_to_guid")
    public let replyToGUID: String?
    @Column("thread_originator_guid")
    public let threadOriginatorGUID: String?
    @Column("thread_originator_part")
    public let threadOriginatorPart: String?
    /// Added in Ventura. Apple nanosecond timestamp. Stringify at JSON/API
    /// boundaries when it needs to cross into JavaScript.
    @Column("date_retracted")
    public let dateRetracted: Int?
    /// Added in Ventura. Apple nanosecond timestamp. Stringify at JSON/API
    /// boundaries when it needs to cross into JavaScript.
    @Column("date_edited")
    public let dateEdited: Int?
    /// Added in Ventura.
    @Column("was_detonated", as: ZeroDefaultIntRepresentation.self)
    public let wasDetonated: Int
    @Column("schedule_type", as: ZeroDefaultIntRepresentation.self)
    public let scheduleType: Int

    // Extensions selected by mapped-message queries. These are not columns on
    // the `message` table; they come from joins or computed SQL aliases.
    public let threadID: String?
    public let chatRowID: Int?
    @Column("room_name")
    public let roomName: String?
    public let participantID: String?
    public let otherID: String?
}

@Selection
public struct MappedChatRow: MappedDatabaseRow {
    @Column("ROWID")
    public let rowID: Int
    public let guid: String
    @Column(as: ZeroDefaultIntRepresentation.self)
    public let state: Int
    public let properties: Data?
    @Column("chat_identifier")
    public let chatIdentifier: String?
    @Column("room_name")
    public let roomName: String?
    @Column("account_login")
    public let accountLogin: String?
    @Column("last_addressed_handle")
    public let lastAddressedHandle: String?
    @Column("display_name")
    public let displayName: String?
    @Column("group_id")
    public let groupID: String?
    /// Apple nanosecond timestamp of the latest message read in this chat.
    /// Stringify at JSON/API boundaries when it needs to cross into JavaScript.
    @Column("last_read_message_timestamp")
    public let lastReadMessageTimestamp: Int?

    // Extensions selected by mapped-thread queries. These are not columns on
    // the `chat` table; they are computed SQL aliases.
    public let msgDate: Int?
}

@Selection
public struct MappedAttachmentRow: MappedDatabaseRow {
    public let msgRowID: Int
    public let filename: String?
    @Column("transfer_name")
    public let transferName: String?
    @Column("total_bytes")
    public let totalBytes: Int?
    @Column("is_sticker")
    public let isSticker: Int?
    public let attachmentID: String?
    @Column("transfer_state")
    public let transferState: Int?

    // Extensions added after fetching attachment rows. These are not columns on
    // the `attachment` table; they are derived from the file path/metadata.
    @Ephemeral
    public var ext: String? = nil
    /// This is not `filename`, intentionally.
    @Ephemeral
    public var fileName: String? = nil
    @Ephemeral
    public var filePath: String? = nil
    @Ephemeral
    public var size: [String: Int]? = nil

    public init(
        msgRowID: Int,
        filename: String?,
        transferName: String?,
        totalBytes: Int?,
        isSticker: Int?,
        attachmentID: String?,
        transferState: Int?,
        ext: String? = nil,
        fileName: String? = nil,
        filePath: String? = nil,
        size: [String: Int]? = nil
    ) {
        self.msgRowID = msgRowID
        self.filename = filename
        self.transferName = transferName
        self.totalBytes = totalBytes
        self.isSticker = isSticker
        self.attachmentID = attachmentID
        self.transferState = transferState
        self.ext = ext
        self.fileName = fileName
        self.filePath = filePath
        self.size = size
    }
}

@Selection
public struct MappedHandleRow: MappedDatabaseRow {
    // Extensions selected by mapped-handle queries. `chatID` comes from
    // `chat_handle_join`, and `participantID` aliases `handle.id`.
    //
    // Canonicalization notes:
    // https://www.notion.so/beeper/Canonicalization-Notes-255a168aa37080c189c0d616724830e4
    @Column("chat_id")
    public let chatID: Int?
    /// Phone number, email, business URN, SMS shortcode, etc. SMS shortcodes
    /// may have `(smsft_rm)`, `(smsft)`, etc. appended for unknown reasons.
    public let participantID: String?
    /// Contains the raw ID if `participantID` was canonicalized.
    @Column("uncanonicalized_id")
    public let uncanonicalizedID: String?

    public init(chatID: Int?, participantID: String?, uncanonicalizedID: String?) {
        self.chatID = chatID
        self.participantID = participantID
        self.uncanonicalizedID = uncanonicalizedID
    }
}

@Selection
public struct MappedReactionMessageRow: MappedDatabaseRow {
    @Column("ROWID")
    public let rowID: Int
    @Column("is_from_me")
    public let isFromMe: Int
    @Column("handle_id")
    public let handleID: Int?
    @Column("associated_message_type")
    public let associatedMessageType: Int
    @Column("associated_message_guid")
    public let associatedMessageGUID: String
    /// Added in Sequoia.
    @Column("associated_message_emoji")
    public let associatedMessageEmoji: String?

    // Extension selected by mapped-reaction queries. This aliases `handle.id`
    // for the sender associated with the reaction message.
    public let participantID: String?
}
