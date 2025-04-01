import type { MessageCell } from './SwiftServer/lib'

type NumberBool = 0 | 1
// taken from chat.db on big sur
type MessageRow = {
  ROWID: number
  guid: string
  text: string
  /** kb: 0 for all my messages */
  replace: number
  service_center: string
  handle_id: number
  subject: string
  /** kb: NULL for all my messages */
  country: string
  attributedBody: Buffer
  /** kb: 10 for all my messages */
  version: number
  type: NumberBool
  /** "iMessage" or "SMS" – might have other values in really old databases (from iChat days) */
  service: string
  account: string
  account_guid: string
  /** number representing error code, 0 is success */
  error: number
  /** @deprecated values in this column will frequently lose precision */
  date: number
  /** @deprecated values in this column will frequently lose precision */
  date_read: number
  /** @deprecated values in this column will frequently lose precision */
  date_delivered: number
  is_delivered: number
  /** kb: 1 for all my messages */
  is_finished: number
  is_emote: number
  /** slightly different from is_sent */
  is_from_me: NumberBool
  is_empty: number
  is_delayed: number
  is_auto_reply: number
  is_prepared: number
  is_read: number
  is_system_message: number
  /** slightly different from is_from_me */
  is_sent: NumberBool
  has_dd_results: number
  is_service_message: number
  /** kb: 0 for all my messages */
  is_forward: number
  was_downgraded: NumberBool
  /** kb: 0 for all my messages */
  is_archive: number
  cache_has_attachments: number
  cache_roomnames: string
  was_data_detected: number
  was_deduplicated: number
  is_audio_message: NumberBool
  is_played: number
  /** @deprecated values in this column will frequently lose precision */
  date_played: number
  item_type: number
  other_handle: number
  group_title: string
  group_action_type: number
  share_status: number
  share_direction: number
  is_expirable: number
  expire_state: number
  message_action_type: number
  message_source: number
  associated_message_guid: string
  associated_message_type: number
  balloon_bundle_id: string
  payload_data: Buffer
  expressive_send_style_id: string
  associated_message_range_location: number
  associated_message_range_length: number
  time_expressive_send_played: number
  message_summary_info: Buffer
  ck_sync_state: number
  ck_record_id: string
  ck_record_change_tag: string
  destination_caller_id: string
  sr_ck_sync_state: number
  sr_ck_record_id: string
  sr_ck_record_change_tag: string
  /** kb: 0 for all my messages */
  is_corrupt: number
  reply_to_guid: string
  sort_id: number
  /** kb: 0 for all my messages */
  is_spam: number
  has_unseen_mention: number
  thread_originator_guid: string
  thread_originator_part: string
  // added in monterey:
  syndication_ranges: string
  synced_syndication_ranges: string
  was_delivered_quietly: number
  did_notify_recipient: number
  // added in ventura:
  /** @deprecated values in this column will frequently lose precision */
  date_retracted: number
  /** @deprecated values in this column will frequently lose precision */
  date_edited: number
  was_detonated: NumberBool
  part_count: number
  // added in ventura 13.1:
  is_stewie: NumberBool
  // added in ventura 13.2 – 13.4.1:
  is_kt_verified: NumberBool
  // added in sequoia
  associated_message_emoji: string
}

// taken from chat.db on big sur
export type ChatRow = {
  ROWID: number
  guid: string
  style: number
  state: number
  account_id: string
  properties: Buffer
  chat_identifier: string
  service_name: string
  room_name: string
  account_login: string
  is_archived: number
  last_addressed_handle: string
  display_name: string
  group_id: string
  is_filtered: NumberBool
  successful_query: NumberBool
  engram_id: string
  server_change_token: string
  ck_sync_state: NumberBool
  original_group_id: string
  last_read_message_timestamp: number
  sr_server_change_token: string
  sr_ck_sync_state: number
  cloudkit_record_id: string
  sr_cloudkit_record_id: string
  last_addressed_sim_id: string
  is_blackholed: NumberBool
  // added in monterey:
  syndication_date: number
  syndication_type: number
  // added in ventura:
  is_recovered: NumberBool
}

// db-api.ts -> SQLS
export type MappedMessageRow = MessageRow & {
  threadID: string
  room_name: string
  participantID: string
  otherID: string

  dateString: string
  dateReadString: string
  dateDeliveredString: string
  // ventura+
  dateEditedString?: string
  dateRetractedString?: string
}

// db-api.ts -> SQLS
export type MappedReactionMessageRow = Pick<
MappedMessageRow,
'is_from_me' |
'handle_id' |
'associated_message_type' |
'associated_message_guid' |
'associated_message_emoji' |
'participantID'
>

// db-api.ts -> SQLS
export type MappedChatRow = ChatRow & {
  msgDateString: string
  /** `last_read_message_timestamp` but as a string to avoid precision loss */
  dateLastMessageReadString: string
}

// db-api.ts -> SQLS
export type MappedAttachmentRow = {
  msgRowID: number
  filename: string
  transfer_name: string
  is_sticker: number
  attachmentID: string
  transfer_state: number

  size?: { width: number, height: number }
  ext: string
  fileName: string // this is not MappedAttachmentRow.filename and intentional
  filePath: string
}

export interface OTRValue {
  /** The zero-based index pointing to the beginning of this part of the original message. */
  lo: number

  /** The length of this part of the original message. */
  le: number
}

// db-api.ts -> SQLS
export type MappedHandleRow = {
  participantID: string
  uncanonicalized_id?: string
}

export interface MessageSummaryInfo {
  amc?: number // 0, 3
  ust?: number // 1
  amsa?: string // "com.apple.siri"
  ams?: string // "Quick brown fox..."

  /**
    * The message edit history, present for messages that have been partially
    * edited.
    *
    * (TODO: Check if this is present for edited _non-partial_ messages.)
    *
    * The index corresponds to {@linkcode otr}.
    */
  ec?: Record<`${number}`, Array<{
    // TODO: Investigate. Likely an attributed string.
    t: Buffer

    // TODO: Investigate. Likely a timestamp of when this part of the message
    // was edited.
    d: number
  }>>

  /**
    * The indexes in {@linkcode otr} that have been unsent.
    */
  rp?: number[]

  /**
    * The indexes in {@linkcode otr} that have been edited.
    */
  ep?: number[]

  /**
    * An ordered record representing the structure of the original message
    * body, present on partially unsent/edited messages. It's important to note
    * that the `attributedBody` of the message at this point only reflects the
    * message in its latest state, and completely lacks the unsent portions;
    * therefore, this data can be used to determine where to interleave UI that
    * indicates that parts of a message was unsent.
    *
    * The properties are ascending numerical strings, with the values
    * describing the starting indexes and lengths of each part of the original
    * message body.
    */
  // NOTE: Not sure why this isn't just an array. Maybe there can be other keys?
  otr?: Record<`${number}`, OTRValue>
}

// custom

export type AXMessageSelection = Omit<MessageCell, 'overlay'>
