import path from 'path'
import { groupBy, omit, truncate, findLast } from 'lodash'
import { Thread, Message, Participant, MessageAttachment, MessageAttachmentType, MessageActionType, MessageBehavior, Size, MessageReaction } from '@textshq/platform-sdk'

import { ASSOC_MSG_TYPE, EXPRESSIVE_MSGS, HEADING_SENDER_NAME_CONSTANT, AttachmentTransferState, BalloonBundleID, supportedReactions } from './constants'
import { fromAppleTime, replaceTilde, stringifyWithArrayBuffers } from './util'
import { getPayloadData, getPayloadProps } from './payload'
import safeBplitParse from './safe-bplist-parse'
import IMAGE_EXTS from './image-exts.json'
import AUDIO_EXTS from './audio-exts.json'
import VIDEO_EXTS from './video-exts.json'
import { decodeAttributedString } from './SwiftServer/lib'
import type ThreadReadStore from './thread-read-store'
import type { MappedAttachmentRow, MappedChatRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow } from './types'

const OBJ_REPLACEMENT_CHAR = '\uFFFC' // ￼
const IMSG_EXTENSION_CHAR = '\uFFFD' // �

const assocMsgGuidPrefix = /^(p:\d\/|bp:)/
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

const serializeMessageRow = (msgRow: MappedMessageRow) =>
  omit(msgRow, ['attributedBody', 'message_summary_info'])

const removeObjReplacementChar = (text: string) => {
  if (!text?.includes(OBJ_REPLACEMENT_CHAR)) return text
  // @ts-expect-error fix after changing es target
  return text.replaceAll(OBJ_REPLACEMENT_CHAR, ' ').trim()
}

function assignReactions(message: Message, _reactionRows: MappedReactionMessageRow[] = [], filterIndex: number, currentUserID: string) {
  const reactions: MessageReaction[] = []
  const reactionRows = filterIndex != null
    ? _reactionRows.filter(r => r.associated_message_guid.startsWith(`p:${filterIndex}/`))
    : _reactionRows
  reactionRows.forEach(reaction => {
    const assocMsgType = ASSOC_MSG_TYPE[reaction.associated_message_type]
    if (assocMsgType !== 'sticker' && assocMsgType) {
      const [actionType, actionKey] = assocMsgType.split('_') || []
      const participantID = (reaction.is_from_me || (!reaction.participantID && reaction.handle_id === 0)) ? currentUserID : reaction.participantID
      if (actionType === 'reacted') {
        reactions.push({
          id: participantID,
          reactionKey: supportedReactions[actionKey]?.render,
          participantID,
        })
      } else if (actionType === 'unreacted') {
        const index = reactions.findIndex(r => r.id === participantID)
        if (index > -1) reactions.splice(index, 1)
      }
    }
  })
  if (reactions.length > 0) message.reactions = reactions
}

function mapMessage(msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] = [], reactionRows: MappedReactionMessageRow[], currentUserID: string, addThreadIDs = false): Message[] {
  if (msgRow.was_data_detected === 0) return
  const attachments = attachmentRows.map(mapAttachment).filter(Boolean)
  const isSMS = msgRow.service === 'SMS'
  const isGroup = !!msgRow.room_name
  const m: Message = {
    _original: stringifyWithArrayBuffers([serializeMessageRow(msgRow), attachmentRows, currentUserID]),
    id: msgRow.msgID,
    cursor: msgRow.date.toString(),
    timestamp: fromAppleTime(msgRow.date),
    senderID: (msgRow.is_from_me || (!msgRow.participantID && msgRow.handle_id === 0)) ? currentUserID : msgRow.participantID,
    text: (msgRow.subject ? `${msgRow.subject}\n` : '') + (removeObjReplacementChar(msgRow.text) || ''),
    isSender: msgRow.is_from_me === 1,
    isErrored: msgRow.error !== 0,
    isDelivered: true, // msgRow.is_delivered === 1,
    seen: isGroup ? undefined : fromAppleTime(msgRow.date_read),
    attachments,
    textFooter: msgRow.expressive_send_style_id
      ? `(Sent with ${(EXPRESSIVE_MSGS[msgRow.expressive_send_style_id] || msgRow.expressive_send_style_id)} effect)`
      : undefined,
    extra: { isSMS },
  }
  if (addThreadIDs) m.threadID = msgRow.threadID
  if (msgRow.is_read) {
    m.behavior = MessageBehavior.KEEP_READ
  }
  if (msgRow.subject) {
    m.textAttributes = {
      entities: [{
        from: 0,
        to: msgRow.subject.length,
        bold: true,
      }],
    }
  }
  if (msgRow.attributedBody) {
    const attributes = decodeAttributedString(msgRow.attributedBody)
    if (attributes) {
      const entities = attributes
        .filter(att => att.key === '__kIMMentionConfirmedMention')
        .map(att => ({
          from: att.from,
          to: att.to,
          mentionedUser: { id: att.value },
        }))
      if (entities.length) m.textAttributes = { entities }
    }
  }
  // {
  //   "amc" => 0
  //   "amsa" => "com.apple.siri"
  //   "ust" => 1
  // }
  if (msgRow.message_summary_info) {
    const msi = safeBplitParse(Buffer.from(msgRow.message_summary_info))
    if (msi?.amsa === 'com.apple.siri') {
      m.textFooter = 'Sent with Siri'
    }
  }
  const payloadData = getPayloadData(msgRow)
  Object.assign(m, getPayloadProps(payloadData, attachments, msgRow.balloon_bundle_id))
  if (msgRow.balloon_bundle_id === BalloonBundleID.DIGITAL_TOUCH) {
    m.textHeading = 'Digital Touch Message'
  } else if (msgRow.balloon_bundle_id === BalloonBundleID.HANDWRITING) {
    m.textHeading = 'Handwritten Message'
  } else if (msgRow.balloon_bundle_id === BalloonBundleID.BIZ_EXTENSION) {
    m.textHeading = 'Business Chat Extension'
    if (m.attachments[0]) m.attachments[0].size = { height: 80, width: 80 }
  }
  // @ts-expect-error fix after changing es target
  m.text = m.text.replaceAll(IMSG_EXTENSION_CHAR, '')
  if (msgRow.associated_message_guid) {
    m.linkedMessageID = msgRow.associated_message_guid.replace(assocMsgGuidPrefix, '')
    const assocMsgType = ASSOC_MSG_TYPE[msgRow.associated_message_type]
    if (assocMsgType !== 'sticker' && assocMsgType) {
      m.isAction = !isSMS // apple imessage has a bug where sms can be reacted to
      const [actionType, actionKey] = assocMsgType.split('_') || []
      const reactionType = {
        reacted: MessageActionType.MESSAGE_REACTION_CREATED,
        unreacted: MessageActionType.MESSAGE_REACTION_DELETED,
      }[actionType]
      if (reactionType) {
        m.action = {
          type: reactionType,
          messageID: m.linkedMessageID,
          participantID: m.senderID,
          reactionKey: actionKey,
        }
        if (supportedReactions[actionKey]) {
          m.parseTemplate = true
          // todo fix for localized reaction messages
          m.text = `{{sender}}: ${truncate(m.text.replace(whitespaceRegexGlobal, ' '), { length: 50 })}`
          m.isHidden = true
        }
      } else if (assocMsgType === 'heading') {
        m.text = m.text.replace(HEADING_SENDER_NAME_CONSTANT, m.isSender ? `{{${msgRow.participantID}}}` : `{{${currentUserID}}}`)
        m.parseTemplate = true
      }
    }
  }
  if (msgRow.thread_originator_guid) {
    /**
     * looks like X:X:Y (0:0:1, 2:2:1, 2:2:18)
     * X = message part index
     * Y = original quoted message length
     */
    const firstPart = msgRow.thread_originator_part?.split(':')?.[0]
    m.linkedMessageID = msgRow.thread_originator_guid + (firstPart === '0' ? '' : `_${firstPart}`)
  }
  if (m.text.startsWith('/me ')) {
    m.text = m.text.replace('/me ', '{{sender}} ')
    m.isAction = true
    m.parseTemplate = true
  }
  if (msgRow.item_type !== 0) {
    m.isAction = true
    m.parseTemplate = true
    if (msgRow.item_type === 1) {
      m.behavior = MessageBehavior.SILENT
      m.text = msgRow.group_action_type === 1
        ? `{{sender}} removed {{${msgRow.otherID}}} from the conversation`
        : `{{sender}} added {{${msgRow.otherID}}} to the conversation`
      m.action = {
        type: msgRow.group_action_type === 1 ? MessageActionType.THREAD_PARTICIPANTS_ADDED : MessageActionType.THREAD_PARTICIPANTS_REMOVED,
        participantIDs: [msgRow.otherID],
        actorParticipantID: m.senderID,
      }
    } else if (msgRow.item_type === 2) {
      m.behavior = MessageBehavior.SILENT
      m.text = msgRow.group_title == null
        ? '{{sender}} removed the name from the conversation'
        : `{{sender}} named the conversation "${msgRow.group_title}"`
      m.action = {
        type: MessageActionType.THREAD_TITLE_UPDATED,
        title: msgRow.group_title,
        actorParticipantID: m.senderID,
      }
    } else if (msgRow.item_type === 3) {
      m.behavior = MessageBehavior.SILENT
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
    } else if (msgRow.item_type === 4) {
      m.behavior = MessageBehavior.SILENT
      m.text = msgRow.share_status === 1
        ? '{{sender}} stopped sharing location'
        : '{{sender}} started sharing location'
    } else if (msgRow.item_type === 5) {
      m.behavior = MessageBehavior.SILENT
      m.text = '{{sender}} kept an audio message from you.'
    } else if (msgRow.item_type === 6) {
      m.text = 'FaceTime Call'
    }
  }
  const mapped: Message[] = [m]
  if (attachments.length > 0 && !m.links?.length && !m.tweets?.length) { // should split
    if (!m.text) {
      mapped.length = 0 // remove existing message if no text
    } else {
      m.id = `${msgRow.msgID}_${attachments.length}`
      m.attachments = undefined
    }
    assignReactions(m, reactionRows, attachments.length, currentUserID)
    mapped.unshift(...attachments.map<Message>((att, attIndex) => {
      const am: Message = {
        ...m,
        id: attIndex === 0 ? msgRow.msgID : `${msgRow.msgID}_${attIndex}`,
        text: null,
        attachments: [att],
      }
      assignReactions(am, reactionRows, attIndex, currentUserID)
      return am
    }))
  } else {
    assignReactions(m, reactionRows, undefined, currentUserID)
  }
  return mapped
}

function mapParticipant({ participantID, uncanonicalized_id }: MappedHandleRow, displayName: string = undefined) {
  if (!participantID) return
  const id = participantID
  const participant: Participant = { id }
  const isEmail = id.includes('@')
  const isBusiness = id.startsWith('urn:')
  const isPhone = !isBusiness && !isEmail && /\d/.test(id)
  if (isBusiness) participant.fullName = displayName
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
  handleRowsMap: { [threadID: string]: MappedHandleRow[] }
  mapMessageArgsMap?: { [threadID: string]: [MappedMessageRow[], MappedAttachmentRow[], MappedReactionMessageRow[]] }
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
  const selfParticipant: Participant = currentUserID === handleRows[0]?.participantID
    ? undefined
    : { ...mapParticipant({ participantID: selfID }), id: currentUserID, isSelf: true }
  const participants = [...handleRows.map(h => mapParticipant(h, chat.display_name)), selfParticipant].filter(Boolean)
  const isGroup = !!chat.room_name
  const isReadOnly = chat.state === 0 && chat.properties != null
  const messages = mapMessageArgs ? mapMessages(...mapMessageArgs, currentUserID) : []
  /*
    props = {
      "com.apple.iChat.LastArchivedMessageID": [ 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX', 101010 ],
      "groupPhotoGuid": "at_0_B97968BB-52C9-4898-88D2-6AA60E7B99D5"
      "LSMD": 2021-07-18T20:19:33.038Z
      "messageHandshakeState": 1
      "numberOfTimesRespondedtoThread": 1
      "pv": 2
      "shouldForceToSMS": false
      "ignoreAlertsFlag": false
      "hasResponded": true
    }
  */
  const props = chat.properties ? safeBplitParse(Buffer.from(chat.properties)) : null
  const messageRows = mapMessageArgs?.[0]
  const lastNonActionMessage = messageRows ? findLast(messageRows, r => r.item_type === 0) : undefined
  const isUnreadInSqlite = lastNonActionMessage?.is_read === 0 && lastNonActionMessage?.is_from_me === 0
  const thread: Thread = {
    _original: stringifyWithArrayBuffers([chat, handleRows]),
    id: chat.guid,
    title: chat.display_name,
    imgURL: props?.groupPhotoGuid ? replaceTilde(context.groupImagesMap?.[props?.groupPhotoGuid]) : undefined,
    isUnread: isUnreadInSqlite && threadReadStore.isThreadUnread(chat.guid, messages[messages.length - 1]?.id),
    // this is not working, mute state doesn't seem to get persisted to chat.db
    // mutedUntil: props?.ignoreAlertsFlag ? 'forever' : undefined,
    isReadOnly,
    type: isGroup ? 'group' : 'single',
    messages: {
      hasMore: true,
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

export function mapMessages(messages: MappedMessageRow[], attachmentRows: MappedAttachmentRow[], reactionRows: MappedReactionMessageRow[], currentUserID: string, addThreadIDs = false): Message[] {
  const groupedAttachmentRows = groupBy(attachmentRows, 'msgRowID')
  const groupedReactionRows = groupBy(reactionRows, r => r.associated_message_guid.replace(assocMsgGuidPrefix, ''))
  return messages
    .flatMap(message => mapMessage(message, groupedAttachmentRows[message.msgRowID], groupedReactionRows[message.guid], currentUserID, addThreadIDs))
    .filter(Boolean)
}
