import Foundation
import SQLite

/// Runtime counterparts to the historical TypeScript row types preserved in
/// DatabaseSchemaNotes.swift. Database queries decode into these structs
/// directly; dictionaries are produced lazily only for `_original` payloads and
/// final JSON surfaces.

public protocol MappedDatabaseRow {
    var object: [String: Any] { get }
}

public struct MappedRowColumnIndexes {
    private let indexesByName: [String: Int]

    public init(_ names: [String]) {
        indexesByName = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
    }

    func index(for name: String) -> Int? {
        indexesByName[name]
    }
}

public extension Sequence where Element: MappedDatabaseRow {
    var objects: [[String: Any]] {
        map(\.object)
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
    public let service: String?
    public let error: Int
    public let date: Int?
    public let dateRead: Int?
    public let dateDelivered: Int?
    public let isDelivered: Int
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
    public let associatedMessageEmoji: String?
    public let balloonBundleID: String?
    public let payloadData: Data?
    public let expressiveSendStyleID: String?
    public let messageSummaryInfo: Data?
    public let threadOriginatorGUID: String?
    public let threadOriginatorPart: String?
    public let dateRetracted: Int?
    public let dateEdited: Int?
    public let wasDetonated: Int
    public let scheduleType: Int

    // Extensions selected by mapped-message queries. These are not columns on
    // the `message` table; they come from joins or computed SQL aliases.
    public let threadID: String?
    public let chatRowID: Int?
    public let roomName: String?
    public let participantID: String?
    public let otherID: String?

    public init(object: [String: Any]) throws {
        rowID = try object.requiredInt("ROWID", row: Self.self)
        guid = try object.requiredString("guid", row: Self.self)
        text = object.string("text")
        subject = object.string("subject")
        attributedBody = object.data("attributedBody")
        service = object.string("service")
        error = object.int("error") ?? 0
        date = object.int("date")
        dateRead = object.int("date_read")
        dateDelivered = object.int("date_delivered")
        isDelivered = object.int("is_delivered") ?? 0
        isFromMe = object.int("is_from_me") ?? 0
        isRead = object.int("is_read") ?? 0
        isAudioMessage = object.int("is_audio_message") ?? 0
        itemType = object.int("item_type") ?? 0
        handleID = object.int("handle_id")
        groupTitle = object.string("group_title")
        groupActionType = object.int("group_action_type") ?? 0
        shareStatus = object.int("share_status") ?? 0
        associatedMessageGUID = object.string("associated_message_guid")
        associatedMessageType = object.int("associated_message_type") ?? 0
        associatedMessageEmoji = object.string("associated_message_emoji")
        balloonBundleID = object.string("balloon_bundle_id")
        payloadData = object.data("payload_data")
        expressiveSendStyleID = object.string("expressive_send_style_id")
        messageSummaryInfo = object.data("message_summary_info")
        threadOriginatorGUID = object.string("thread_originator_guid")
        threadOriginatorPart = object.string("thread_originator_part")
        dateRetracted = object.int("date_retracted")
        dateEdited = object.int("date_edited")
        wasDetonated = object.int("was_detonated") ?? 0
        scheduleType = object.int("schedule_type") ?? 0
        threadID = object.string("threadID")
        chatRowID = object.int("chatRowID")
        roomName = object.string("room_name")
        participantID = object.string("participantID")
        otherID = object.string("otherID")
    }

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

    public var object: [String: Any] {
        compactObject([
            "ROWID": rowID,
            "guid": guid,
            "text": text,
            "subject": subject,
            "attributedBody": attributedBody,
            "service": service,
            "error": error,
            "date": date,
            "date_read": dateRead,
            "date_delivered": dateDelivered,
            "is_delivered": isDelivered,
            "is_from_me": isFromMe,
            "is_read": isRead,
            "is_audio_message": isAudioMessage,
            "item_type": itemType,
            "handle_id": handleID,
            "group_title": groupTitle,
            "group_action_type": groupActionType,
            "share_status": shareStatus,
            "associated_message_guid": associatedMessageGUID,
            "associated_message_type": associatedMessageType,
            "associated_message_emoji": associatedMessageEmoji,
            "balloon_bundle_id": balloonBundleID,
            "payload_data": payloadData,
            "expressive_send_style_id": expressiveSendStyleID,
            "message_summary_info": messageSummaryInfo,
            "thread_originator_guid": threadOriginatorGUID,
            "thread_originator_part": threadOriginatorPart,
            "date_retracted": dateRetracted,
            "date_edited": dateEdited,
            "was_detonated": wasDetonated,
            "schedule_type": scheduleType,
            "threadID": threadID,
            "chatRowID": chatRowID,
            "room_name": roomName,
            "participantID": participantID,
            "otherID": otherID,
        ])
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

    public var object: [String: Any] {
        compactObject([
            "ROWID": rowID,
            "guid": guid,
            "state": state,
            "properties": properties,
            "chat_identifier": chatIdentifier,
            "room_name": roomName,
            "account_login": accountLogin,
            "last_addressed_handle": lastAddressedHandle,
            "display_name": displayName,
            "group_id": groupID,
            "last_read_message_timestamp": lastReadMessageTimestamp,
            "msgDate": msgDate,
        ])
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

    public init(object: [String: Any]) throws {
        self.init(
            msgRowID: try object.requiredInt("msgRowID", row: Self.self),
            filename: object.string("filename"),
            transferName: object.string("transfer_name"),
            totalBytes: object.int("total_bytes"),
            isSticker: object.int("is_sticker"),
            attachmentID: object.string("attachmentID"),
            transferState: object.int("transfer_state"),
            ext: object.string("ext"),
            fileName: object.string("fileName"),
            filePath: object.string("filePath"),
            size: object["size"] as? [String: Int]
        )
    }

    public var object: [String: Any] {
        compactObject([
            "msgRowID": msgRowID,
            "filename": filename,
            "transfer_name": transferName,
            "total_bytes": totalBytes,
            "is_sticker": isSticker,
            "attachmentID": attachmentID,
            "transfer_state": transferState,
            "ext": ext,
            "fileName": fileName,
            "filePath": filePath,
            "size": size,
        ])
    }
}

public struct MappedHandleRow: MappedDatabaseRow {
    // Extensions selected by mapped-handle queries. `chatID` comes from
    // `chat_handle_join`, and `participantID` aliases `handle.id`.
    public let chatID: Int?
    public let participantID: String?
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

    public var object: [String: Any] {
        compactObject([
            "chat_id": chatID,
            "participantID": participantID,
            "uncanonicalized_id": uncanonicalizedID,
        ])
    }
}

public struct MappedReactionMessageRow: MappedDatabaseRow {
    public let rowID: Int
    public let isFromMe: Int
    public let handleID: Int?
    public let associatedMessageType: Int
    public let associatedMessageGUID: String
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

    public init(object: [String: Any]) throws {
        rowID = object.int("ROWID") ?? 0
        isFromMe = object.int("is_from_me") ?? 0
        handleID = object.int("handle_id")
        associatedMessageType = try object.requiredInt("associated_message_type", row: Self.self)
        associatedMessageGUID = try object.requiredString("associated_message_guid", row: Self.self)
        associatedMessageEmoji = object.string("associated_message_emoji")
        participantID = object.string("participantID")
    }

    public var object: [String: Any] {
        compactObject([
            "ROWID": rowID,
            "is_from_me": isFromMe,
            "handle_id": handleID,
            "associated_message_type": associatedMessageType,
            "associated_message_guid": associatedMessageGUID,
            "associated_message_emoji": associatedMessageEmoji,
            "participantID": participantID,
        ])
    }
}

private func compactObject(_ pairs: [String: Any?]) -> [String: Any] {
    pairs.compactMapValues { value in
        guard let value, !(value is NSNull) else {
            return nil
        }
        return value
    }
}

private extension Dictionary where Key == String, Value == Any {
    func requiredString<RowType>(_ key: String, row: RowType.Type) throws -> String {
        guard let value = string(key) else {
            throw MappedDatabaseRowError.missingRequiredColumn(row: String(describing: row), column: key)
        }
        return value
    }

    func requiredInt<RowType>(_ key: String, row: RowType.Type) throws -> Int {
        guard let value = int(key) else {
            throw MappedDatabaseRowError.missingRequiredColumn(row: String(describing: row), column: key)
        }
        return value
    }

    func string(_ key: String) -> String? {
        guard let value = self[key], !(value is NSNull) else {
            return nil
        }
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return "\(number)"
        default:
            return nil
        }
    }

    func int(_ key: String) -> Int? {
        guard let value = self[key], !(value is NSNull) else {
            return nil
        }
        switch value {
        case let integer as Int:
            return integer
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    func data(_ key: String) -> Data? {
        guard let value = self[key], !(value is NSNull) else {
            return nil
        }
        switch value {
        case let data as Data:
            return data
        case let data as NSData:
            return data as Data
        default:
            return nil
        }
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
