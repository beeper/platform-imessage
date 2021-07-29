import path from 'path'
import { groupBy, omit, truncate } from 'lodash'
import { Thread, Message, Participant, MessageAttachment, MessageAttachmentType, MessageActionType, Size } from '@textshq/platform-sdk'

import { ASSOC_MSG_TYPE, EXPRESSIVE_MSGS, HEADING_SENDER_NAME_CONSTANT, AttachmentTransferState, BalloonBundleID, supportedReactions } from './constants'
import { fromAppleTime, replaceTilde, enhancedStringify, unpackTime } from './util'
import { getPayloadData, getPayloadProps } from './payload'
import safeBplitParse from './safe-bplist-parse'
import IMAGE_EXTS from './image-exts.json'
import AUDIO_EXTS from './audio-exts.json'
import VIDEO_EXTS from './video-exts.json'
import type ThreadReadStore from './thread-read-store'
import type { MappedAttachmentRow, MappedChatRow, MappedMessageRow } from './types'

const OBJ_REPLACEMENT_CHAR = '\uFFFC' // ￼
const IMSG_EXTENSION_CHAR = '\uFFFD' // �

const whitespaceRegexGlobal = /\s+/g

function mapAttachment(a: MappedAttachmentRow): MessageAttachment {
  if (a.transfer_state == null) return
  const filePath = replaceTilde(a.filename)
  const { base, ext: _ext } = filePath ? path.parse(filePath) : { base: a.transfer_name, ext: '' }
  const fileName = a.transfer_name || base
  const ext = _ext.slice(1).toLowerCase()
  const common = {
    id: a.attachmentID,
    fileName,
    srcURL: filePath,
    loading: a.transfer_state !== AttachmentTransferState.DOWNLOADED,
  }
  if (filePath) common.srcURL = 'file://' + encodeURI(filePath)
  if (IMAGE_EXTS.includes(ext) || ext === 'pluginpayloadattachment') {
    const size: Size = a.is_sticker ? { height: 80, width: undefined } : undefined
    if (ext === 'png') {
      common.srcURL = 'asset://$accountID/' + Buffer.from(filePath).toString('hex')
    }
    return { ...common, type: MessageAttachmentType.IMG, size }
  }
  if (VIDEO_EXTS.includes(ext)) {
    return { ...common, type: MessageAttachmentType.VIDEO }
  }
  if (AUDIO_EXTS.includes(ext) && !['caf', 'amr'].includes(ext)) {
    return { ...common, type: MessageAttachmentType.AUDIO }
  }
  return { ...common, type: MessageAttachmentType.UNKNOWN }
}

function serializeMessageRow(row: MappedMessageRow) {
  return {
    ...omit(row, ['attributedBody', 'message_summary_info']),
    payload_data: row.payload_data && Buffer.from(row.payload_data as Uint8Array),
  }
}

const removeObjReplacementChar = (text: string) => {
  if (!text?.includes(OBJ_REPLACEMENT_CHAR)) return text
  // @ts-expect-error fix after changing es target
  return text.replaceAll(OBJ_REPLACEMENT_CHAR, ' ').trim()
}

export function mapMessage(row: MappedMessageRow, attachmentRows: MappedAttachmentRow[] = [], currentUserID: string): Message {
  if (row.was_data_detected === 0) return
  const attachments = attachmentRows.map(mapAttachment).filter(Boolean)
  const isSMS = row.service === 'SMS'
  const isGroup = !!row.room_name
  const m: Message = {
    _original: enhancedStringify([serializeMessageRow(row), attachmentRows, currentUserID]),
    id: row.msgID,
    cursor: row.date.toString(),
    timestamp: fromAppleTime(row.date),
    senderID: (row.is_from_me || (!row.participantID && row.handle_id === 0)) ? currentUserID : row.participantID,
    text: (row.subject ? `${row.subject}\n` : '') + (removeObjReplacementChar(row.text) || ''),
    isSender: row.is_from_me === 1,
    isErrored: row.error !== 0,
    isDelivered: true, // row.is_delivered === 1,
    seen: isGroup ? undefined : fromAppleTime(row.date_read),
    attachments,
    textFooter: row.expressive_send_style_id
      ? `(Sent with ${(EXPRESSIVE_MSGS[row.expressive_send_style_id] || row.expressive_send_style_id)} effect)`
      : undefined,
    extra: { isSMS },
  }
  if (row.subject) {
    m.textAttributes = {
      entities: [{
        from: 0,
        to: row.subject.length,
        bold: true,
      }],
    }
  }
  // {
  //   "amc" => 0
  //   "amsa" => "com.apple.siri"
  //   "ust" => 1
  // }
  if (row.message_summary_info) {
    const msi = safeBplitParse(Buffer.from(row.message_summary_info))
    if (msi?.amsa === 'com.apple.siri') {
      m.textFooter = 'Sent with Siri'
    }
  }
  const payloadData = getPayloadData(row)
  Object.assign(m, getPayloadProps(payloadData, m, row))
  if (row.balloon_bundle_id === BalloonBundleID.DIGITAL_TOUCH) {
    m.textHeading = 'Digital Touch Message'
  } else if (row.balloon_bundle_id === BalloonBundleID.HANDWRITING) {
    m.textHeading = 'Handwritten Message'
  } else if (row.balloon_bundle_id === BalloonBundleID.BIZ_EXTENSION) {
    m.textHeading = 'Business Chat Extension'
    if (m.attachments[0]) m.attachments[0].size = { height: 80, width: 80 }
  }
  // @ts-expect-error fix after changing es target
  m.text = m.text.replaceAll(IMSG_EXTENSION_CHAR, '')
  if (row.associated_message_guid) {
    m.linkedMessageID = row.associated_message_guid.replace(/^(p:\d\/|bp:)/, '')
    const assocMsgType = ASSOC_MSG_TYPE[row.associated_message_type]
    if (assocMsgType !== 'sticker' && assocMsgType) {
      m.isAction = !isSMS // apple imessage has a bug where sms can be reacted to
      const [actionType, actionKey] = assocMsgType.split('_') || []
      const reactionType = {
        reacted: MessageActionType.MESSAGE_REACTION_CREATED,
        unreacted: MessageActionType.MESSAGE_REACTION_DELETED,
      }[actionType]
      if (reactionType) {
        const emoji = supportedReactions[actionKey]?.render
        m.action = {
          type: reactionType,
          messageID: m.linkedMessageID,
          participantID: m.senderID,
          reactionKey: actionKey,
        }
        if (emoji) {
          m.parseTemplate = true
          m.text = `{{sender}}: ${emoji} ${truncate(m.text.replace(whitespaceRegexGlobal, ' '), { length: 50 })}`
        }
      } else if (assocMsgType === 'heading') {
        m.text = m.text.replace(HEADING_SENDER_NAME_CONSTANT, m.isSender ? `{{${row.participantID}}}` : `{{${currentUserID}}}`)
        m.parseTemplate = true
      }
    }
  }
  if (row.thread_originator_guid) {
    m.linkedMessageID = row.thread_originator_guid
  }
  if (m.text.startsWith('/me ')) {
    m.text = m.text.replace('/me ', '{{sender}} ')
    m.isAction = true
    m.parseTemplate = true
  }
  if (row.item_type !== 0) {
    m.isAction = true
    m.parseTemplate = true
    if (row.item_type === 1) {
      m.text = row.group_action_type === 1
        ? `{{sender}} removed {{${row.otherID}}} from the conversation`
        : `{{sender}} added {{${row.otherID}}} to the conversation`
      m.action = {
        type: row.group_action_type === 1 ? MessageActionType.THREAD_PARTICIPANTS_ADDED : MessageActionType.THREAD_PARTICIPANTS_REMOVED,
        participantIDs: [row.otherID],
        actorParticipantID: m.senderID,
      }
    } else if (row.item_type === 2) {
      m.text = row.group_title == null
        ? '{{sender}} removed the name from the conversation'
        : `{{sender}} named the conversation "${row.group_title}"`
      m.action = {
        type: MessageActionType.THREAD_TITLE_UPDATED,
        title: row.group_title,
        actorParticipantID: m.senderID,
      }
    } else if (row.item_type === 3) {
      const firstAttachmentRow = attachmentRows[0]
      if (firstAttachmentRow?.attachmentID) {
        m.text = '{{sender}} changed the group photo'
        m.attachments = []
        m.action = {
          type: MessageActionType.THREAD_IMG_CHANGED,
          actorParticipantID: m.senderID,
        }
      } else {
        m.text = '{{sender}} left the conversation'
        m.action = {
          type: MessageActionType.THREAD_PARTICIPANTS_REMOVED,
          actorParticipantID: m.senderID,
          participantIDs: [m.senderID],
        }
      }
    } else if (row.item_type === 4) {
      m.text = row.share_status === 1
        ? '{{sender}} stopped sharing location'
        : '{{sender}} started sharing location'
    } else if (row.item_type === 5) {
      m.text = '{{sender}} kept an audio message from you.'
    } else if (row.item_type === 6) {
      m.text = 'FaceTime Call'
    }
  }
  return m
}

function mapParticipant({ participantID, uncanonicalized_id, display_name }: any) {
  if (!participantID) return
  const id = participantID
  const participant: Participant = { id }
  const isEmail = id.includes('@')
  const isBusiness = id.startsWith('urn:')
  const isPhone = !isBusiness && !isEmail && /\d/.test(id)
  if (isBusiness) participant.fullName = display_name
  else if (isEmail) participant.email = id
  else if (isPhone) participant.phoneNumber = id
  if (!isPhone && uncanonicalized_id) {
    participant.id = uncanonicalized_id
  }
  return participant
}

export const mapAccountLogin = (al: string) => al?.replace(/^E:/, '')

type Context = {
  currentUserID: string
  handleRowsMap: { [threadID: string]: any[] }
  mapMessageArgsMap?: { [threadID: string]: [MappedMessageRow[], MappedAttachmentRow[]] }
  groupImagesMap?: { [attachmentID: string]: string }
  threadReadStore: ThreadReadStore
}

export function mapThread(
  chat: MappedChatRow,
  context: Context,
): Thread {
  const { currentUserID, threadReadStore } = context
  const handleRows = context.handleRowsMap[chat.guid]
  const mapMessageArgs = context.mapMessageArgsMap?.[chat.guid]
  const selfID = chat.last_addressed_handle || mapAccountLogin(chat.account_login) || currentUserID
  const selfParticipant: Participant = { ...mapParticipant({ participantID: selfID }), id: currentUserID, isSelf: true }
  const { display_name } = chat
  const participants = [...handleRows.map(h => mapParticipant({ ...h, display_name })), selfParticipant].filter(Boolean)
  const isGroup = !!chat.room_name
  const isReadOnly = chat.state === 0 && chat.properties != null
  const messages = mapMessageArgs ? mapMessages(mapMessageArgs[0], mapMessageArgs[1], currentUserID) : []
  /*
    {
      "groupPhotoGuid" => "at_0_B97968BB-52C9-4898-88D2-6AA60E7B99D5"
      "LSMD" => 2020-11-15 20:18:56 +0000
      "messageHandshakeState" => 1
      "numberOfTimesRespondedtoThread" => 1
      "pv" => 2
      "shouldForceToSMS" => 0
    }
  */
  const props = chat.properties ? safeBplitParse(Buffer.from(chat.properties)) : null
  // isUnreadInSqlite is not 100% correct
  const isUnreadInSqlite = !isReadOnly
    && !messages[0]?.isSender
    // chat.msgDate is the latest message's date
    && (chat.last_read_message_timestamp === 0 || unpackTime(chat.last_read_message_timestamp) < unpackTime(chat.msgDate))
  const thread: Thread = {
    _original: enhancedStringify([chat, handleRows]),
    id: chat.guid,
    title: chat.display_name,
    imgURL: props?.groupPhotoGuid ? replaceTilde(context.groupImagesMap?.[props?.groupPhotoGuid]) : undefined,
    isUnread: isUnreadInSqlite && threadReadStore.isThreadUnread(chat.guid, messages[0]?.id),
    isReadOnly,
    type: isGroup ? 'group' : 'single',
    messages: {
      hasMore: true,
      oldestCursor: String(chat.msgDate),
      items: messages,
    },
    participants: {
      hasMore: false,
      items: participants,
    },
    timestamp: fromAppleTime(chat.msgDate) || new Date(),
  }
  if (thread.imgURL) thread.imgURL = 'file://' + encodeURI(thread.imgURL)
  return thread
}

export const mapThreads = (chatRows: MappedChatRow[], context: Context) =>
  chatRows.map(chat => mapThread(chat, context))

export function mapMessages(rows: MappedMessageRow[], attachmentRows: MappedAttachmentRow[], currentUserID: string, addThreadIDs = false): Message[] {
  const grouped = groupBy(attachmentRows, 'msgRowID')
  return rows.map(r => {
    const m = mapMessage(r, grouped[r.msgRowID], currentUserID)
    if (addThreadIDs) m.threadID = r.threadID
    return m
  }).filter(Boolean)
}
