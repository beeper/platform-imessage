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

public struct MappedMessageRow: MappedDatabaseRow {
    public typealias QueryOutput = Self

    public let rowID: Int
    public let guid: String
    public let text: String?
    public let subject: String?
    public let attributedBody: Data?
    /// Usually "iMessage" or "SMS"; very old databases may contain other
    /// values from the iChat era.
    public let service: String?
    /// Numeric error code; `0` means success.
    public let error: Int
    /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
    /// needs to cross into JavaScript.
    public let date: Int?
    /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
    /// needs to cross into JavaScript.
    public let dateRead: Int?
    /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
    /// needs to cross into JavaScript.
    public let dateDelivered: Int?
    public let isDelivered: Int
    /// Slightly different from `is_sent`.
    public let isFromMe: Int
    public let isRead: Int
    public let isAudioMessage: Int
    public let itemType: Int
    public let handleID: Int?
    public let groupTitle: String?
    public let groupActionType: Int
    public let shareStatus: Int
    public let associatedMessageGUID: String?
    public let associatedMessageType: Int
    /// Added in Sequoia.
    public let associatedMessageEmoji: String?
    public let balloonBundleID: String?
    public let payloadData: Data?
    public let expressiveSendStyleID: String?
    public let messageSummaryInfo: Data?
    /// GUID of a related message. iMessage uses this for reaction removal rows
    /// to point back at the hidden reaction-add message row.
    public let replyToGUID: String?
    public let threadOriginatorGUID: String?
    public let threadOriginatorPart: String?
    /// Added in Ventura. Apple nanosecond timestamp. Stringify at JSON/API
    /// boundaries when it needs to cross into JavaScript.
    public let dateRetracted: Int?
    /// Added in Ventura. Apple nanosecond timestamp. Stringify at JSON/API
    /// boundaries when it needs to cross into JavaScript.
    public let dateEdited: Int?
    /// Added in Ventura.
    public let wasDetonated: Int
    public let scheduleType: Int

    // Extensions selected by mapped-message queries. These are not columns on
    // the `message` table; they come from joins or computed SQL aliases.
    public let threadID: String?
    public let chatRowID: Int?
    public let roomName: String?
    public let participantID: String?
    public let otherID: String?

    public init(decoder: inout some QueryDecoder) throws {
        rowID = try decoder.requiredInt("ROWID", row: Self.self)
        guid = try decoder.requiredString("guid", row: Self.self)
        text = try decoder.optionalString()
        subject = try decoder.optionalString()
        attributedBody = try decoder.optionalData()
        service = try decoder.optionalString()
        error = try decoder.optionalInt() ?? 0
        date = try decoder.optionalInt()
        dateRead = try decoder.optionalInt()
        dateDelivered = try decoder.optionalInt()
        isDelivered = try decoder.optionalInt() ?? 0
        isFromMe = try decoder.optionalInt() ?? 0
        isRead = try decoder.optionalInt() ?? 0
        isAudioMessage = try decoder.optionalInt() ?? 0
        itemType = try decoder.optionalInt() ?? 0
        handleID = try decoder.optionalInt()
        groupTitle = try decoder.optionalString()
        groupActionType = try decoder.optionalInt() ?? 0
        shareStatus = try decoder.optionalInt() ?? 0
        associatedMessageGUID = try decoder.optionalString()
        associatedMessageType = try decoder.optionalInt() ?? 0
        associatedMessageEmoji = try decoder.optionalString()
        balloonBundleID = try decoder.optionalString()
        payloadData = try decoder.optionalData()
        expressiveSendStyleID = try decoder.optionalString()
        messageSummaryInfo = try decoder.optionalData()
        replyToGUID = try decoder.optionalString()
        threadOriginatorGUID = try decoder.optionalString()
        threadOriginatorPart = try decoder.optionalString()
        dateRetracted = try decoder.optionalInt()
        dateEdited = try decoder.optionalInt()
        wasDetonated = try decoder.optionalInt() ?? 0
        scheduleType = try decoder.optionalInt() ?? 0
        threadID = try decoder.optionalString()
        chatRowID = try decoder.optionalInt()
        roomName = try decoder.optionalString()
        participantID = try decoder.optionalString()
        otherID = try decoder.optionalString()
    }
}

public struct MappedChatRow: MappedDatabaseRow {
    public typealias QueryOutput = Self

    public let rowID: Int
    public let guid: String
    public let state: Int
    public let properties: Data?
    public let chatIdentifier: String?
    public let roomName: String?
    public let accountLogin: String?
    public let lastAddressedHandle: String?
    public let displayName: String?
    public let groupID: String?
    /// Apple nanosecond timestamp of the latest message read in this chat.
    /// Stringify at JSON/API boundaries when it needs to cross into JavaScript.
    public let lastReadMessageTimestamp: Int?

    // Extensions selected by mapped-thread queries. These are not columns on
    // the `chat` table; they are computed SQL aliases.
    public let msgDate: Int?

    public init(decoder: inout some QueryDecoder) throws {
        rowID = try decoder.requiredInt("ROWID", row: Self.self)
        guid = try decoder.requiredString("guid", row: Self.self)
        state = try decoder.optionalInt() ?? 0
        properties = try decoder.optionalData()
        chatIdentifier = try decoder.optionalString()
        roomName = try decoder.optionalString()
        accountLogin = try decoder.optionalString()
        lastAddressedHandle = try decoder.optionalString()
        displayName = try decoder.optionalString()
        groupID = try decoder.optionalString()
        lastReadMessageTimestamp = try decoder.optionalInt()
        msgDate = try decoder.optionalInt()
    }
}

public struct MappedAttachmentRow: MappedDatabaseRow {
    public typealias QueryOutput = Self

    public let msgRowID: Int
    public let filename: String?
    public let transferName: String?
    public let totalBytes: Int?
    public let isSticker: Int?
    public let attachmentID: String?
    public let transferState: Int?

    // Extensions added after fetching attachment rows. These are not columns on
    // the `attachment` table; they are derived from the file path/metadata.
    public let ext: String?
    /// This is not `filename`, intentionally.
    public let fileName: String?
    public let filePath: String?
    public let size: [String: Int]?

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

    public init(decoder: inout some QueryDecoder) throws {
        try self.init(
            msgRowID: decoder.requiredInt("msgRowID", row: Self.self),
            filename: decoder.optionalString(),
            transferName: decoder.optionalString(),
            totalBytes: decoder.optionalInt(),
            isSticker: decoder.optionalInt(),
            attachmentID: decoder.optionalString(),
            transferState: decoder.optionalInt()
        )
    }
}

public struct MappedHandleRow: MappedDatabaseRow {
    public typealias QueryOutput = Self

    // Extensions selected by mapped-handle queries. `chatID` comes from
    // `chat_handle_join`, and `participantID` aliases `handle.id`.
    //
    // Canonicalization notes:
    // https://www.notion.so/beeper/Canonicalization-Notes-255a168aa37080c189c0d616724830e4
    public let chatID: Int?
    /// Phone number, email, business URN, SMS shortcode, etc. SMS shortcodes
    /// may have `(smsft_rm)`, `(smsft)`, etc. appended for unknown reasons.
    public let participantID: String?
    /// Contains the raw ID if `participantID` was canonicalized.
    public let uncanonicalizedID: String?

    public init(chatID: Int?, participantID: String?, uncanonicalizedID: String?) {
        self.chatID = chatID
        self.participantID = participantID
        self.uncanonicalizedID = uncanonicalizedID
    }

    public init(decoder: inout some QueryDecoder) throws {
        chatID = try decoder.optionalInt()
        participantID = try decoder.optionalString()
        uncanonicalizedID = try decoder.optionalString()
    }
}

public struct MappedReactionMessageRow: MappedDatabaseRow {
    public typealias QueryOutput = Self

    public let rowID: Int
    public let isFromMe: Int
    public let handleID: Int?
    public let associatedMessageType: Int
    public let associatedMessageGUID: String
    /// Added in Sequoia.
    public let associatedMessageEmoji: String?

    // Extension selected by mapped-reaction queries. This aliases `handle.id`
    // for the sender associated with the reaction message.
    public let participantID: String?

    public init(decoder: inout some QueryDecoder) throws {
        rowID = try decoder.requiredInt("ROWID", row: Self.self)
        isFromMe = try decoder.requiredInt("is_from_me", row: Self.self)
        handleID = try decoder.optionalInt()
        associatedMessageType = try decoder.requiredInt("associated_message_type", row: Self.self)
        associatedMessageGUID = try decoder.requiredString("associated_message_guid", row: Self.self)
        associatedMessageEmoji = try decoder.optionalString()
        participantID = try decoder.optionalString()
    }
}
