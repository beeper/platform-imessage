import Foundation

/// Documentation-only schema notes migrated from the old TypeScript raw row
/// types. These stubs intentionally are not used by the mappers; they preserve
/// field-level database observations that are useful when investigating new
/// macOS `chat.db` columns or mapper regressions.
///
/// Wrapped in `#if false` so the compiler doesn't typecheck this dead code.
/// This is reference material, like a markdown file with type syntax.
///
/// These notes are checked against the schema fixtures in `fixtures/`. A field
/// can disappear across macOS releases, so don't assume older observations are
/// still present without comparing the fixtures.
#if false
enum DatabaseSchemaNotes {
    typealias NumberBool = Int

    /// Columns observed in the `message` table, originally taken from
    /// `chat.db` on Big Sur and extended as newer macOS releases added fields.
    struct MessageRow {
        var rowID: Int
        var guid: String
        var text: String?

        /// Observed by kb as `0` for all messages.
        var replace: Int
        var serviceCenter: String?
        var handleID: Int?
        var subject: String?
        /// Observed by kb as `NULL` for all messages.
        var country: String?
        var attributedBody: Data?
        /// Observed by kb as `10` for all messages.
        var version: Int
        var type: NumberBool
        /// Usually "iMessage" or "SMS"; very old databases may contain other
        /// values from the iChat era.
        var service: String?
        var account: String?
        var accountGUID: String?
        /// Numeric error code; `0` means success.
        var error: Int

        /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
        /// needs to cross into JavaScript.
        var date: Int
        /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
        /// needs to cross into JavaScript.
        var dateRead: Int
        /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
        /// needs to cross into JavaScript.
        var dateDelivered: Int

        var isDelivered: Int
        /// Observed by kb as `1` for all messages.
        var isFinished: Int
        var isEmote: Int
        /// Slightly different from `is_sent`.
        var isFromMe: NumberBool
        var isEmpty: Int
        var isDelayed: Int
        var isAutoReply: Int
        var isPrepared: Int
        var isRead: Int
        var isSystemMessage: Int
        /// Slightly different from `is_from_me`.
        var isSent: NumberBool
        var hasDDResults: Int
        var isServiceMessage: Int
        /// Observed by kb as `0` for all messages.
        var isForward: Int
        var wasDowngraded: NumberBool
        /// Observed by kb as `0` for all messages.
        var isArchive: Int
        var cacheHasAttachments: Int
        var cacheRoomNames: String?
        var wasDataDetected: Int
        var wasDeduplicated: Int
        var isAudioMessage: NumberBool
        var isPlayed: Int
        /// Prefer reading this through SQLite as text or converting in Swift;
        /// JavaScript `number` frequently loses precision for Apple nanosecond
        /// timestamps.
        var datePlayed: Int
        var itemType: Int
        var otherHandle: Int?
        var groupTitle: String?
        var groupActionType: Int
        var shareStatus: Int
        var shareDirection: Int
        var isExpirable: Int
        var expireState: Int
        var messageActionType: Int
        var messageSource: Int
        var associatedMessageGUID: String?
        var associatedMessageType: Int
        var balloonBundleID: String?
        var payloadData: Data?
        var expressiveSendStyleID: String?
        var associatedMessageRangeLocation: Int
        var associatedMessageRangeLength: Int
        var timeExpressiveSendPlayed: Int
        var messageSummaryInfo: Data?
        var ckSyncState: Int
        var ckRecordID: String?
        var ckRecordChangeTag: String?
        var destinationCallerID: String?
        var srCKSyncState: Int
        var srCKRecordID: String?
        var srCKRecordChangeTag: String?
        /// Observed by kb as `0` for all messages.
        var isCorrupt: Int
        var replyToGUID: String?
        var sortID: Int
        /// Observed by kb as `0` for all messages.
        var isSpam: Int
        var hasUnseenMention: Int
        var threadOriginatorGUID: String?
        var threadOriginatorPart: String?

        // Added in Monterey.
        var syndicationRanges: String?
        var syncedSyndicationRanges: String?
        var wasDeliveredQuietly: Int
        var didNotifyRecipient: Int

        // Added in Ventura.
        /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
        /// needs to cross into JavaScript.
        var dateRetracted: Int
        /// Apple nanosecond timestamp. Stringify at JSON/API boundaries when it
        /// needs to cross into JavaScript.
        var dateEdited: Int
        var wasDetonated: NumberBool
        var partCount: Int

        // Added in Ventura 13.1.
        var isStewie: NumberBool

        // Observed in Tahoe.
        var isSOS: NumberBool
        var isCritical: NumberBool
        var biaReferenceID: String?

        // Added in Ventura 13.2 through 13.4.1.
        var isKTVerified: NumberBool

        // Observed in Tahoe.
        var fallbackHash: String?

        // Added in Sequoia.
        var associatedMessageEmoji: String?

        var isPendingSatelliteSend: Int
        var needsRelay: Int
        var scheduleType: Int
        var scheduleState: Int
        var sentOrReceivedOffGrid: Int
        var dateRecovered: Int

        // Observed in Tahoe.
        var isTimeSensitive: NumberBool
        var ckChatID: String?
        var indexState: Int
    }

    /// Columns observed in the `chat` table, originally taken from `chat.db`
    /// on Big Sur and extended as newer macOS releases added fields.
    struct ChatRow {
        var rowID: Int
        var guid: String
        var style: Int
        var state: Int
        var accountID: String?
        var properties: Data?
        var chatIdentifier: String?
        var serviceName: String?
        var roomName: String?
        var accountLogin: String?
        var isArchived: Int
        var lastAddressedHandle: String?
        var displayName: String?
        var groupID: String?
        var isFiltered: NumberBool
        var successfulQuery: NumberBool
        var engramID: String?
        var serverChangeToken: String?
        var ckSyncState: NumberBool
        var originalGroupID: String?
        var lastReadMessageTimestamp: Int
        var srServerChangeToken: String?
        var srCKSyncState: Int
        var cloudKitRecordID: String?
        var srCloudKitRecordID: String?
        var lastAddressedSIMID: String?
        var isBlackholed: NumberBool

        // Added in Monterey.
        var syndicationDate: Int
        var syndicationType: Int

        // Added in Ventura.
        var isRecovered: NumberBool

        // Observed in Tahoe.
        var isDeletingIncomingMessages: NumberBool
        var isPendingReview: NumberBool
    }

    /// Extra fields selected by the historical mapped-message SQL.
    struct MappedMessageRow {
        var threadID: String
        var roomName: String?
        var participantID: String?
        var otherID: String?
    }

    /// Extra fields selected by the historical mapped-chat SQL.
    struct MappedChatRow {
        var msgDate: Int?
    }

    /// Extra fields selected by the historical mapped-attachment SQL.
    struct MappedAttachmentRow {
        var msgRowID: Int
        var filename: String?
        var transferName: String?
        var totalBytes: Int
        var isSticker: Int
        var attachmentID: String?
        var transferState: Int
        var size: PixelSize?
        var ext: String
        /// This is not `MappedAttachmentRow.filename`, intentionally.
        var fileName: String
        var filePath: String
    }

    /// Extra fields selected by the historical mapped-handle SQL.
    ///
    /// Canonicalization notes:
    /// https://www.notion.so/beeper/Canonicalization-Notes-255a168aa37080c189c0d616724830e4
    struct MappedHandleRow {
        /// Phone number, email, business URN, SMS shortcode, etc. SMS
        /// shortcodes may have `(smsft_rm)`, `(smsft)`, etc. appended for
        /// unknown reasons.
        var participantID: String
        /// Contains the raw ID if `participantID` was canonicalized.
        var uncanonicalizedID: String?
    }

    struct MappedReactionMessageRow {
        var rowID: Int
        var isFromMe: NumberBool
        var handleID: Int?
        var associatedMessageType: Int
        var associatedMessageGUID: String?
        var associatedMessageEmoji: String?
        var participantID: String?
    }

    struct PixelSize {
        var width: Int
        var height: Int
    }

    struct OTRValue {
        /// The zero-based index pointing to the beginning of this part of the
        /// original message.
        var lo: Int
        /// The length of this part of the original message.
        var le: Int
    }

    /// Notes for the `message_summary_info` bplist payload.
    struct MessageSummaryInfo {
        /// Observed value examples: `0`, `3`.
        var amc: Int?
        /// Observed value example: `1`.
        var ust: Int?
        /// Observed value example: `com.apple.siri`.
        var amsa: String?
        /// Observed value example: the summarized text.
        var ams: String?

        /// Message edit history, present for messages that have been partially
        /// edited. TODO: check if this is present for edited non-partial
        /// messages. The index corresponds to `otr`.
        var ec: [String: [EditHistoryItem]]?

        /// Indexes in `otr` that have been unsent.
        var rp: [Int]?

        /// Indexes in `otr` that have been edited.
        var ep: [Int]?

        /// Ordered record representing the structure of the original message
        /// body, present on partially unsent or edited messages.
        ///
        /// The `attributedBody` at this point only reflects the latest state
        /// and completely lacks the unsent portions; this data can be used to
        /// determine where to interleave UI indicating that parts of a message
        /// were unsent.
        ///
        /// The properties are ascending numerical strings. The values describe
        /// the starting indexes and lengths of each part of the original body.
        /// This may be a dictionary rather than an array because other keys may
        /// be possible.
        var otr: [String: OTRValue]?
    }

    struct EditHistoryItem {
        /// TODO: investigate. Likely an attributed string.
        var t: Data
        /// TODO: investigate. Likely a timestamp of when this part of the
        /// message was edited.
        var d: Int
    }
}
#endif
