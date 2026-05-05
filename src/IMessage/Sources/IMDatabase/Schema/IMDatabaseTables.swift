/// Table and column names observed in `fixtures/schema-monterey.sql`,
/// `fixtures/schema-ventura.sql`, and `fixtures/schema-tahoe.sql`.

enum SQLiteSequenceTable: IMDatabaseTable {
    static let sqlName = "sqlite_sequence"

    enum Column: String, IMDatabaseColumn {
        case name
        case seq
    }
}

enum MessageTable: IMDatabaseTable {
    static let sqlName = "message"

    enum Column: String, IMDatabaseColumn {
        case rowID = "ROWID"
        case guid
        case text
        case replace
        case serviceCenter = "service_center"
        case handleID = "handle_id"
        case subject
        case country
        case attributedBody = "attributedBody"
        case version
        case messageType = "type"
        case service
        case account
        case accountGUID = "account_guid"
        case error
        case date
        case dateRead = "date_read"
        case dateDelivered = "date_delivered"
        case isDelivered = "is_delivered"
        case isFinished = "is_finished"
        case isEmote = "is_emote"
        case isFromMe = "is_from_me"
        case isEmpty = "is_empty"
        case isDelayed = "is_delayed"
        case isAutoReply = "is_auto_reply"
        case isPrepared = "is_prepared"
        case isRead = "is_read"
        case isSystemMessage = "is_system_message"
        case isSent = "is_sent"
        case hasDDResults = "has_dd_results"
        case isServiceMessage = "is_service_message"
        case isForward = "is_forward"
        case wasDowngraded = "was_downgraded"
        case isArchive = "is_archive"
        case cacheHasAttachments = "cache_has_attachments"
        case cacheRoomnames = "cache_roomnames"
        case wasDataDetected = "was_data_detected"
        case wasDeduplicated = "was_deduplicated"
        case isAudioMessage = "is_audio_message"
        case isPlayed = "is_played"
        case datePlayed = "date_played"
        case itemType = "item_type"
        case otherHandle = "other_handle"
        case groupTitle = "group_title"
        case groupActionType = "group_action_type"
        case shareStatus = "share_status"
        case shareDirection = "share_direction"
        case isExpirable = "is_expirable"
        case expireState = "expire_state"
        case messageActionType = "message_action_type"
        case messageSource = "message_source"
        case associatedMessageGUID = "associated_message_guid"
        case associatedMessageType = "associated_message_type"
        case balloonBundleID = "balloon_bundle_id"
        case payloadData = "payload_data"
        case expressiveSendStyleID = "expressive_send_style_id"
        case associatedMessageRangeLocation = "associated_message_range_location"
        case associatedMessageRangeLength = "associated_message_range_length"
        case timeExpressiveSendPlayed = "time_expressive_send_played"
        case messageSummaryInfo = "message_summary_info"
        case ckSyncState = "ck_sync_state"
        case ckRecordID = "ck_record_id"
        case ckRecordChangeTag = "ck_record_change_tag"
        case destinationCallerID = "destination_caller_id"
        case isCorrupt = "is_corrupt"
        case replyToGUID = "reply_to_guid"
        case sortID = "sort_id"
        case isSpam = "is_spam"
        case hasUnseenMention = "has_unseen_mention"
        case threadOriginatorGUID = "thread_originator_guid"
        case threadOriginatorPart = "thread_originator_part"
        case syndicationRanges = "syndication_ranges"
        case syncedSyndicationRanges = "synced_syndication_ranges"
        case wasDeliveredQuietly = "was_delivered_quietly"
        case didNotifyRecipient = "did_notify_recipient"
        case dateRetracted = "date_retracted"
        case dateEdited = "date_edited"
        case wasDetonated = "was_detonated"
        case partCount = "part_count"
        case isStewie = "is_stewie"
        case isSOS = "is_sos"
        case isCritical = "is_critical"
        case biaReferenceID = "bia_reference_id"
        case isKTVerified = "is_kt_verified"
        case fallbackHash = "fallback_hash"
        case associatedMessageEmoji = "associated_message_emoji"
        case isPendingSatelliteSend = "is_pending_satellite_send"
        case needsRelay = "needs_relay"
        case scheduleType = "schedule_type"
        case scheduleState = "schedule_state"
        case sentOrReceivedOffGrid = "sent_or_received_off_grid"
        case dateRecovered = "date_recovered"
        case isTimeSensitive = "is_time_sensitive"
        case ckChatID = "ck_chat_id"
        case indexState = "index_state"
    }
}

enum ChatTable: IMDatabaseTable {
    static let sqlName = "chat"

    enum Column: String, IMDatabaseColumn {
        case rowID = "ROWID"
        case guid
        case style
        case state
        case accountID = "account_id"
        case properties
        case chatIdentifier = "chat_identifier"
        case serviceName = "service_name"
        case roomName = "room_name"
        case accountLogin = "account_login"
        case isArchived = "is_archived"
        case lastAddressedHandle = "last_addressed_handle"
        case displayName = "display_name"
        case groupID = "group_id"
        case isFiltered = "is_filtered"
        case successfulQuery = "successful_query"
        case engramID = "engram_id"
        case serverChangeToken = "server_change_token"
        case ckSyncState = "ck_sync_state"
        case originalGroupID = "original_group_id"
        case lastReadMessageTimestamp = "last_read_message_timestamp"
        case cloudkitRecordID = "cloudkit_record_id"
        case lastAddressedSIMID = "last_addressed_sim_id"
        case isBlackholed = "is_blackholed"
        case syndicationDate = "syndication_date"
        case syndicationType = "syndication_type"
        case isRecovered = "is_recovered"
        case isDeletingIncomingMessages = "is_deleting_incoming_messages"
        case isPendingReview = "is_pending_review"
    }
}

enum HandleTable: IMDatabaseTable {
    static let sqlName = "handle"

    enum Column: String, IMDatabaseColumn {
        case rowID = "ROWID"
        case id
        case country
        case service
        case uncanonicalizedID = "uncanonicalized_id"
        case personCentricID = "person_centric_id"
    }
}

enum AttachmentTable: IMDatabaseTable {
    static let sqlName = "attachment"

    enum Column: String, IMDatabaseColumn {
        case rowID = "ROWID"
        case guid
        case createdDate = "created_date"
        case startDate = "start_date"
        case filename
        case uti
        case mimeType = "mime_type"
        case transferState = "transfer_state"
        case isOutgoing = "is_outgoing"
        case userInfo = "user_info"
        case transferName = "transfer_name"
        case totalBytes = "total_bytes"
        case isSticker = "is_sticker"
        case stickerUserInfo = "sticker_user_info"
        case attributionInfo = "attribution_info"
        case hideAttachment = "hide_attachment"
        case ckSyncState = "ck_sync_state"
        case ckServerChangeTokenBlob = "ck_server_change_token_blob"
        case ckRecordID = "ck_record_id"
        case originalGUID = "original_guid"
        case isCommSafetySensitive = "is_commsafety_sensitive"
        case emojiImageContentIdentifier = "emoji_image_content_identifier"
        case emojiImageShortDescription = "emoji_image_short_description"
        case previewGenerationState = "preview_generation_state"
    }
}

enum ChatMessageJoinTable: IMDatabaseTable {
    static let sqlName = "chat_message_join"

    enum Column: String, IMDatabaseColumn {
        case chatID = "chat_id"
        case messageID = "message_id"
        case messageDate = "message_date"
        case indexState = "index_state"
    }
}

enum ChatHandleJoinTable: IMDatabaseTable {
    static let sqlName = "chat_handle_join"

    enum Column: String, IMDatabaseColumn {
        case chatID = "chat_id"
        case handleID = "handle_id"
    }
}

enum MessageAttachmentJoinTable: IMDatabaseTable {
    static let sqlName = "message_attachment_join"

    enum Column: String, IMDatabaseColumn {
        case messageID = "message_id"
        case attachmentID = "attachment_id"
    }
}
