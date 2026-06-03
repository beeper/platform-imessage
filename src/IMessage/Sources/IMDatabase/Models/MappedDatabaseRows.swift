import Foundation
import SQLite

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

public protocol MappedDatabaseRow {
    init(row: borrowing Row, columns: MappedRowColumnIndexes) throws
}

public struct MappedRowColumnIndexes {
    private let indexesByName: [String: Int]

    public init(_ names: [String]) {
        indexesByName = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
    }

    public init(statement: Statement) {
        self.init(statement.columnNames)
    }

    func index(for name: String) -> Int? {
        indexesByName[name]
    }
}

public extension Statement {
    func mapRowsUntilDone<T: MappedDatabaseRow>(_: T.Type) throws -> [T] {
        let columns = MappedRowColumnIndexes(statement: self)
        return try mapRowsUntilDone { try T(row: $0, columns: columns) }
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

    public init(row: borrowing Row, columns: MappedRowColumnIndexes) throws {
        rowID = try row.requiredInt("ROWID", columns: columns, row: Self.self)
        guid = try row.requiredString("guid", columns: columns, row: Self.self)
        text = try row.string("text", columns: columns)
        subject = try row.string("subject", columns: columns)
        attributedBody = try row.data("attributedBody", columns: columns)
        service = try row.string("service", columns: columns)
        error = try row.int("error", columns: columns) ?? 0
        date = try row.int("date", columns: columns)
        dateRead = try row.int("date_read", columns: columns)
        dateDelivered = try row.int("date_delivered", columns: columns)
        isDelivered = try row.int("is_delivered", columns: columns) ?? 0
        isFromMe = try row.int("is_from_me", columns: columns) ?? 0
        isRead = try row.int("is_read", columns: columns) ?? 0
        isAudioMessage = try row.int("is_audio_message", columns: columns) ?? 0
        itemType = try row.int("item_type", columns: columns) ?? 0
        handleID = try row.int("handle_id", columns: columns)
        groupTitle = try row.string("group_title", columns: columns)
        groupActionType = try row.int("group_action_type", columns: columns) ?? 0
        shareStatus = try row.int("share_status", columns: columns) ?? 0
        associatedMessageGUID = try row.string("associated_message_guid", columns: columns)
        associatedMessageType = try row.int("associated_message_type", columns: columns) ?? 0
        associatedMessageEmoji = try row.string("associated_message_emoji", columns: columns)
        balloonBundleID = try row.string("balloon_bundle_id", columns: columns)
        payloadData = try row.data("payload_data", columns: columns)
        expressiveSendStyleID = try row.string("expressive_send_style_id", columns: columns)
        messageSummaryInfo = try row.data("message_summary_info", columns: columns)
        replyToGUID = try row.string("reply_to_guid", columns: columns)
        threadOriginatorGUID = try row.string("thread_originator_guid", columns: columns)
        threadOriginatorPart = try row.string("thread_originator_part", columns: columns)
        dateRetracted = try row.int("date_retracted", columns: columns)
        dateEdited = try row.int("date_edited", columns: columns)
        wasDetonated = try row.int("was_detonated", columns: columns) ?? 0
        scheduleType = try row.int("schedule_type", columns: columns) ?? 0
        threadID = try row.string("threadID", columns: columns)
        chatRowID = try row.int("chatRowID", columns: columns)
        roomName = try row.string("room_name", columns: columns)
        participantID = try row.string("participantID", columns: columns)
        otherID = try row.string("otherID", columns: columns)
    }
}

public struct MappedChatRow: MappedDatabaseRow {
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

    public init(row: borrowing Row, columns: MappedRowColumnIndexes) throws {
        rowID = try row.requiredInt("ROWID", columns: columns, row: Self.self)
        guid = try row.requiredString("guid", columns: columns, row: Self.self)
        state = try row.int("state", columns: columns) ?? 0
        properties = try row.data("properties", columns: columns)
        chatIdentifier = try row.string("chat_identifier", columns: columns)
        roomName = try row.string("room_name", columns: columns)
        accountLogin = try row.string("account_login", columns: columns)
        lastAddressedHandle = try row.string("last_addressed_handle", columns: columns)
        displayName = try row.string("display_name", columns: columns)
        groupID = try row.string("group_id", columns: columns)
        lastReadMessageTimestamp = try row.int("last_read_message_timestamp", columns: columns)
        msgDate = try row.int("msgDate", columns: columns)
    }
}

public struct MappedAttachmentRow: MappedDatabaseRow {
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

    public var transferStateValue: Attachment.IMFileTransferState? {
        transferState.map(Attachment.IMFileTransferState.init(rawValue:))
    }

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

    public init(row: borrowing Row, columns: MappedRowColumnIndexes) throws {
        try self.init(
            msgRowID: row.requiredInt("msgRowID", columns: columns, row: Self.self),
            filename: row.string("filename", columns: columns),
            transferName: row.string("transfer_name", columns: columns),
            totalBytes: row.int("total_bytes", columns: columns),
            isSticker: row.int("is_sticker", columns: columns),
            attachmentID: row.string("attachmentID", columns: columns),
            transferState: row.int("transfer_state", columns: columns)
        )
    }
}

public struct MappedHandleRow: MappedDatabaseRow {
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

    public init(row: borrowing Row, columns: MappedRowColumnIndexes) throws {
        chatID = try row.int("chat_id", columns: columns)
        participantID = try row.string("participantID", columns: columns)
        uncanonicalizedID = try row.string("uncanonicalized_id", columns: columns)
    }
}

public struct MappedReactionMessageRow: MappedDatabaseRow {
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

    public init(row: borrowing Row, columns: MappedRowColumnIndexes) throws {
        rowID = try row.requiredInt("ROWID", columns: columns, row: Self.self)
        isFromMe = try row.requiredInt("is_from_me", columns: columns, row: Self.self)
        handleID = try row.int("handle_id", columns: columns)
        associatedMessageType = try row.requiredInt("associated_message_type", columns: columns, row: Self.self)
        associatedMessageGUID = try row.requiredString("associated_message_guid", columns: columns, row: Self.self)
        associatedMessageEmoji = try row.string("associated_message_emoji", columns: columns)
        participantID = try row.string("participantID", columns: columns)
    }
}

private extension Row {
    borrowing func requiredString<RowType>(
        _ key: String,
        columns: MappedRowColumnIndexes,
        row: RowType.Type
    ) throws -> String {
        guard let value = try string(key, columns: columns) else {
            throw MappedDatabaseRowError.missingRequiredColumn(row: String(describing: row), column: key)
        }
        return value
    }

    borrowing func requiredInt<RowType>(
        _ key: String,
        columns: MappedRowColumnIndexes,
        row: RowType.Type
    ) throws -> Int {
        guard let value = try int(key, columns: columns) else {
            throw MappedDatabaseRowError.missingRequiredColumn(row: String(describing: row), column: key)
        }
        return value
    }

    borrowing func string(_ key: String, columns: MappedRowColumnIndexes) throws -> String? {
        guard let index = columns.index(for: key) else {
            return nil
        }
        return try self[index].optionalConverting(String.self)
    }

    borrowing func int(_ key: String, columns: MappedRowColumnIndexes) throws -> Int? {
        guard let index = columns.index(for: key) else {
            return nil
        }
        return try self[index].optionalConverting(Int.self)
    }

    borrowing func data(_ key: String, columns: MappedRowColumnIndexes) throws -> Data? {
        guard let index = columns.index(for: key) else {
            return nil
        }
        return try self[index].optionalConverting(Data.self)
    }
}
