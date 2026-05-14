import IMessageCore

public extension MappedMessageRow {
    init(object: [String: Any]) throws {
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
        replyToGUID = object.string("reply_to_guid")
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

    var object: [String: Any] {
        compactDictionary([
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
            "reply_to_guid": replyToGUID,
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

public extension MappedChatRow {
    var object: [String: Any] {
        compactDictionary([
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

public extension MappedAttachmentRow {
    init(object: [String: Any]) throws {
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

    var object: [String: Any] {
        compactDictionary([
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

public extension MappedHandleRow {
    var object: [String: Any] {
        compactDictionary([
            "chat_id": chatID,
            "participantID": participantID,
            "uncanonicalized_id": uncanonicalizedID,
        ])
    }
}

public extension MappedReactionMessageRow {
    init(object: [String: Any]) throws {
        rowID = object.int("ROWID") ?? 0
        isFromMe = object.int("is_from_me") ?? 0
        handleID = object.int("handle_id")
        associatedMessageType = try object.requiredInt("associated_message_type", row: Self.self)
        associatedMessageGUID = try object.requiredString("associated_message_guid", row: Self.self)
        associatedMessageEmoji = object.string("associated_message_emoji")
        participantID = object.string("participantID")
    }

    var object: [String: Any] {
        compactDictionary([
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
}
