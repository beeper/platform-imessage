import url from 'url'
import { groupBy, omit } from 'lodash'
import { Thread, Message, Participant, Attachment, AttachmentType, MessageActionType, MessageBehavior, Size, MessageReaction, TextAttributes } from '@textshq/platform-sdk'

import { ASSOC_MSG_TYPE, EXPRESSIVE_MSGS, RECEIVER_NAME_CONSTANT, SENDER_NAME_CONSTANT, AttachmentTransferState, BalloonBundleID, supportedReactions, TMP_MOBILE_SMS_PATH, REACTION_VERB_MAP, IS_VENTURA_OR_UP } from './constants'
import { fromAppleTime, replaceTilde, stringifyWithArrayBuffers } from './util'
import { getPayloadData, getPayloadProps } from './payload'
import safeBplistParse from './safe-bplist-parse'
import IMAGE_EXTS from './image-exts.json'
import AUDIO_EXTS from './audio-exts.json'
import VIDEO_EXTS from './video-exts.json'
import swiftServer, { Fragment } from './SwiftServer/lib'
import type ThreadReadStore from './thread-read-store'
import type { MappedAttachmentRow, MappedChatRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow, MessageSummaryInfo, OTRValue } from './types'

const OBJ_REPLACEMENT_CHAR = '\uFFFC' // ￼
const IMSG_EXTENSION_CHAR = '\uFFFD' // �

const assocMsgGuidPrefix = /^p:([-\d]+)\/|bp:/

function mapAttachment(a: MappedAttachmentRow, msgRow: MappedMessageRow): Attachment {
  if (a.transfer_state == null) return
  const { ext, fileName, filePath } = a
  const common = {
    id: a.attachmentID,
    fileName,
    srcURL: filePath,
    loading: a.transfer_state !== AttachmentTransferState.DOWNLOADED,
  } satisfies Partial<Attachment>
  if (filePath) common.srcURL = url.pathToFileURL(filePath).href
  if (IMAGE_EXTS.includes(ext) || ext === 'pluginpayloadattachment') {
    const size: Size = a.is_sticker ? { height: 100, width: undefined } : a.size
    if (ext === 'png') {
      common.srcURL = 'asset://$accountID/' + Buffer.from(filePath).toString('hex')
    }
    return { ...common, type: AttachmentType.IMG, size, isSticker: a.is_sticker === 1 }
  }
  if (VIDEO_EXTS.includes(ext)) {
    return { ...common, type: AttachmentType.VIDEO }
  }
  if (AUDIO_EXTS.includes(ext)) {
    return { ...common, isVoiceNote: msgRow.is_audio_message === 1, type: AttachmentType.AUDIO }
  }
  return { ...common, type: AttachmentType.UNKNOWN }
}

const serializeMessageRow = (msgRow: MappedMessageRow) =>
  omit(msgRow, ['attributedBody', 'message_summary_info'])

const removeObjReplacementChar = (text: string): string => {
  if (!text?.includes(OBJ_REPLACEMENT_CHAR)) return text
  return text.replaceAll(OBJ_REPLACEMENT_CHAR, ' ').trim()
}

function assignReactions(message: Message, _reactionRows: MappedReactionMessageRow[] = [], filterIndex: number, currentUserID: string) {
  const reactions: MessageReaction[] = []
  const reactionRows = filterIndex != null
    ? _reactionRows.filter(r => r.associated_message_guid.startsWith(`p:${filterIndex}/`))
    : _reactionRows
  reactionRows.forEach(reaction => {
    const assocMsgType: string = ASSOC_MSG_TYPE[reaction.associated_message_type]
    if (assocMsgType !== 'sticker' && assocMsgType) {
      const [actionType, actionKey] = assocMsgType.split('_', 2) || []
      const participantID = (reaction.is_from_me || (!reaction.participantID && reaction.handle_id === 0)) ? currentUserID : reaction.participantID
      if (actionType === 'reacted') {
        reactions.push({
          id: participantID,
          reactionKey: actionKey,
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

const enum MessagePartKind {
  TEXT,
  ATTACHMENT,
  UNSENT,
}
interface MessagePartText {
  kind: MessagePartKind.TEXT
  index: number
  text: string
  end: number
  attributes?: TextAttributes
}
interface MessagePartAttachment {
  kind: MessagePartKind.ATTACHMENT
  index: number
  end: number
  attachmentID: string
}
interface MessagePartUnsent {
  kind: MessagePartKind.UNSENT
  index: number
  end: number
}

type MessagePart = MessagePartText | MessagePartAttachment | MessagePartUnsent

function decodeMessageParts(fragments: Fragment[], messageSummaryInfo?: MessageSummaryInfo): MessagePart[] {
  const parts: MessagePart[] = []
  const handledDeletedFragments: number[] = []

  const sortedOriginalRuns: (OTRValue & { index: number })[] = messageSummaryInfo?.otr != null
    ? Object.entries(messageSummaryInfo.otr)
      // Don't depend on the Apple sorting these numerical string keys for us.
      .sort((first, second) => parseInt(first[0], 10) - parseInt(second[0], 10))
      .map(([, value], index) => ({ ...value, ...{ index } }))
    : null

  for (const frag of fragments) {
    if (messageSummaryInfo?.rp != null && messageSummaryInfo.otr != null) {
      // In our traversal of the new message, locate any unsent parts of the original
      // message that we would have since crossed.
      //
      // (This only applies to messages that are partially unsent).
      const crossedDeletedFragments = sortedOriginalRuns.filter(
        (otr, index) => otr.lo < frag.to
          && messageSummaryInfo.rp.includes(index)
          && !handledDeletedFragments.includes(index),
      )

      for (const crossed of crossedDeletedFragments) {
        parts.push({
          kind: MessagePartKind.UNSENT,
          index: parts.length,
          end: 0,
        })
        handledDeletedFragments.push(crossed.index)
      }
    }

    const attachmentID = frag.attributes.__kIMFileTransferGUIDAttributeName
    if (typeof attachmentID === 'string') {
      parts.push({
        kind: MessagePartKind.ATTACHMENT,
        index: parts.length,
        end: frag.to,
        attachmentID,
      })
    } else {
      const partStr = frag.attributes.__kIMMessagePartAttributeName
      if (typeof partStr === 'undefined' || +partStr !== parts.length - 1) {
        parts.push({
          kind: MessagePartKind.TEXT,
          index: parts.length,
          end: 0,
          text: '',
        })
      }
      const textPart = parts[parts.length - 1] as MessagePartText
      textPart.end = frag.to
      textPart.text += frag.text.replace(IMSG_EXTENSION_CHAR, '')
      const mention = frag.attributes.__kIMMentionConfirmedMention
      if (typeof mention === 'string') {
        textPart.attributes = {
          entities: [
            ...(textPart.attributes?.entities || []),
            {
              from: frag.from,
              to: frag.to,
              mentionedUser: { id: mention },
            },
          ],
        }
      }
    }
  }
  for (let i = 1; i < parts.length; i++) {
    const part = parts[i]
    if (part.kind !== MessagePartKind.TEXT) continue
    const start = parts[i - 1]
    part.attributes?.entities?.forEach(e => {
      e.from -= start.end
      e.to -= start.end
    })
  }
  return parts
}

export type MessageWithExtra = Omit<Message, 'extra'> & {
  extra: {
    isSMS?: boolean
    part?: number
  }
}

const UUID_START = 11
const UUID_LENGTH = 36
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export function mapMessage(msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] = [], reactionRows: MappedReactionMessageRow[], currentUserID: string, addThreadIDs = false): MessageWithExtra[] {
  const attachments = attachmentRows.map(a => mapAttachment(a, msgRow)).filter(Boolean)
  const isSMS = msgRow.service === 'SMS'
  const isGroup = !!msgRow.room_name

  const partialMessage: MessageWithExtra = {
    _original: stringifyWithArrayBuffers([serializeMessageRow(msgRow), attachmentRows, currentUserID]),
    id: msgRow.guid,
    cursor: msgRow.date.toString(),
    timestamp: fromAppleTime(msgRow.date),
    senderID: (msgRow.is_from_me || (!msgRow.participantID && msgRow.handle_id === 0)) ? currentUserID : msgRow.participantID,
    // text: (msgRow.subject ? `${msgRow.subject}\n` : '') + (removeObjReplacementChar(msgRow.text) || ''),
    isSender: msgRow.is_from_me === 1,
    isErrored: msgRow.error !== 0,
    isDelivered: msgRow.is_delivered === 1,
    seen: isGroup ? undefined : fromAppleTime(msgRow.date_read),
    extra: {},
  }

  if (msgRow.date_edited) partialMessage.editedTimestamp = fromAppleTime(msgRow.date_edited)
  if (msgRow.date_retracted || msgRow.was_detonated) partialMessage.isDeleted = true
  if (isSMS) partialMessage.extra.isSMS = true
  if (addThreadIDs) partialMessage.threadID = msgRow.threadID
  if (msgRow.is_read) {
    partialMessage.behavior = MessageBehavior.KEEP_READ
  }

  const msi: MessageSummaryInfo = msgRow.message_summary_info ? safeBplistParse(msgRow.message_summary_info) : undefined

  const entirelyUnsent = msi?.otr != null
    && Object.keys(msi.otr).length === 1
    && msi?.rp != null
    && msi.rp[0] === 0

  if (msgRow.item_type !== 0) {
    const m: MessageWithExtra = {
      ...partialMessage,
      isAction: true,
      parseTemplate: true,
    }

    let didFail = false
    switch (msgRow.item_type) {
      case 1:
        m.behavior = MessageBehavior.SILENT
        m.text = msgRow.group_action_type === 1
          ? `{{sender}} removed {{${msgRow.otherID}}} from the conversation`
          : `{{sender}} added {{${msgRow.otherID}}} to the conversation`
        m.action = {
          type: msgRow.group_action_type === 1
            ? MessageActionType.THREAD_PARTICIPANTS_REMOVED
            : MessageActionType.THREAD_PARTICIPANTS_ADDED,
          participantIDs: [msgRow.otherID],
          actorParticipantID: m.senderID,
        }
        break
      case 2:
        m.behavior = MessageBehavior.SILENT
        m.text = msgRow.group_title == null
          ? '{{sender}} removed the name from the conversation'
          : `{{sender}} named the conversation "${msgRow.group_title}"`
        m.action = {
          type: MessageActionType.THREAD_TITLE_UPDATED,
          title: msgRow.group_title,
          actorParticipantID: m.senderID,
        }
        break
      case 3: {
        m.behavior = MessageBehavior.SILENT
        const changedGroupImg = msgRow.group_action_type === 1
        if (changedGroupImg || msgRow.group_action_type === 2) {
          m.text = changedGroupImg
            ? '{{sender}} changed the group photo'
            : '{{sender}} removed the group photo'
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
        break
      }
      case 4:
        m.behavior = MessageBehavior.SILENT
        m.text = msgRow.share_status === 1
          ? '{{sender}} stopped sharing location'
          : '{{sender}} started sharing location'
        break
      case 5:
        m.behavior = MessageBehavior.SILENT
        m.text = '{{sender}} kept an audio message from you.'
        break
      case 6:
        m.text = 'FaceTime Call'
        break
      default:
        didFail = true
        break
    }
    if (!didFail) return [m]
  }

  const partialHeader: Pick<Message, 'textHeading' | 'linkedMessageID'> = {}
  const partialFooter: Pick<Message, 'textFooter'> = msgRow.expressive_send_style_id
    ? { textFooter: `(Sent with ${(EXPRESSIVE_MSGS[msgRow.expressive_send_style_id] || msgRow.expressive_send_style_id)} effect)` }
    : {}

  const payloadData = getPayloadData(msgRow)
  Object.assign(partialMessage, getPayloadProps(payloadData, attachments, msgRow.balloon_bundle_id))

  switch (msgRow.balloon_bundle_id) {
    case BalloonBundleID.DIGITAL_TOUCH: {
      partialHeader.textHeading = 'Digital Touch Message'
      if (TMP_MOBILE_SMS_PATH && msgRow.payload_data) {
        const uuid = Buffer.from(msgRow.payload_data.slice(-(UUID_START + UUID_LENGTH), -UUID_START)).toString('utf-8')
        if (UUID_REGEX.test(uuid)) {
          partialMessage.attachments = [{
            id: uuid,
            type: AttachmentType.VIDEO,
            isGif: true,
            // file:// will mostly work fine but we use asset:// since it can take a few seconds before the file is written to disk by messages.app
            srcURL: `asset://$accountID/dt/${uuid}.mov`,
            // srcURL: url.pathToFileURL(path.join(TMP_MOBILE_SMS_PATH, `${uuid}.mov`)).href,
            size: { width: 144, height: 180 },
          }]
        }
      }
      break
    }
    case BalloonBundleID.HANDWRITING: {
      partialHeader.textHeading = 'Handwritten Message'
      if (TMP_MOBILE_SMS_PATH && msgRow.payload_data) {
        const uuid = Buffer.from(msgRow.payload_data.slice(UUID_START, UUID_START + UUID_LENGTH)).toString('utf-8')
        if (UUID_REGEX.test(uuid)) {
          partialMessage.attachments = [{
            id: uuid,
            type: AttachmentType.IMG,
            isGif: true,
            // todo: since we don't know w & h, we use asset://
            // srcURL: url.pathToFileURL(path.join(TMP_MOBILE_SMS_PATH, `hw_${uuid}_${w}_${h}_${swiftServer.appleInterfaceStyle === 'Dark' ? 'dark' : 'light'}.png`)).href,
            srcURL: `asset://$accountID/hw/${uuid}.png`,
          }]
        }
      }
      break
    }
    case BalloonBundleID.BIZ_EXTENSION: {
      partialHeader.textHeading = 'Business Chat Extension'
      // TODO: Handle busines chats
      // if (m.attachments[0]) m.attachments[0].size = { height: 80, width: 80 }
      break
    }
    default:
  }

  if (msgRow.message_summary_info) {
    if (msi?.amsa === 'com.apple.siri') {
      partialFooter.textFooter = 'Sent with Siri'
    }
  }

  // reply
  if (msgRow.thread_originator_guid) {
    /**
      * looks like X:Y:Z (0:0:1, 2:2:1, 2:2:18, 2:109:158, 18446744073709551615:0:5)
      * X = message part index
      * Y = original quoted message text start
      * Z = length after Y
      *
      * 18446744073709551615 is -1 (https://stackoverflow.com/questions/40608111/why-is-18446744073709551615-1-true)
     */
    let partIndex = msgRow.thread_originator_part?.split(':', 1)?.[0]
    if (partIndex === '0') partIndex = ''
    if (partIndex === '18446744073709551615') partIndex = '-1'
    partialHeader.linkedMessageID = msgRow.thread_originator_guid + (partIndex ? `_${partIndex}` : '')
  }

  let messageParts: MessagePart[] = []
  if (swiftServer && msgRow.attributedBody) {
    const attributes = swiftServer.decodeAttributedString(msgRow.attributedBody)
    if (attributes) {
      messageParts = decodeMessageParts(attributes, msi)
    }
  }
  if (messageParts.length === 0) {
    if (msgRow.attributedBody == null && msi?.rp != null && msi?.otr != null) {
      messageParts = [{ kind: MessagePartKind.UNSENT, index: 0, end: 0 }]
    } else {
      messageParts = [{
        kind: MessagePartKind.TEXT,
        index: 0,
        text: removeObjReplacementChar(msgRow.text || '').replaceAll(IMSG_EXTENSION_CHAR, ''),
      } as MessagePart].concat(...(attachments.map((a, i) => ({
        kind: MessagePartKind.ATTACHMENT,
        attachmentID: a.id,
        index: i + 1,
      })) as MessagePartAttachment[]))
    }
  }

  const addSubjectInline = msgRow.subject && messageParts[0].kind === MessagePartKind.TEXT && messageParts[0].text.length
  if (msgRow.subject && !addSubjectInline) {
    messageParts.unshift({
      kind: MessagePartKind.TEXT,
      index: -1,
      end: 0,
      text: msgRow.subject,
      attributes: {
        entities: [{
          from: 0,
          to: [...msgRow.subject].length,
          bold: true,
        }],
      },
    })
  }

  // messageParts will always be non-empty
  const messages = messageParts.map<MessageWithExtra>((part, partIdx) => {
    const message = { ...partialMessage }
    if (msi?.otr != null && msi?.rp != null) {
      // When a message is partially unsent, the edited timestamp reflects when
      // the (most recent, ostensibly) unsent occurred. Don't expose this, for
      // now, so we don't mislead the user. (Unsending part of a message can be
      // argued to count as a kind of "edit", but yeah.)
      message.editedTimestamp = null
    }

    if (messageParts.length > 1) {
      // we have to copy message.extra, otherwise it shares the object
      // among different message parts
      message.extra = {
        ...message.extra,
        // we mean part number (part.index), not partIdx. The latter is
        // 0-based whereas part.index can be negative for the subject.
        part: part.index,
      }
    }
    // we mean idx, not part number
    if (partIdx === 0) Object.assign(message, partialHeader)
    if (partIdx === messageParts.length - 1) Object.assign(message, partialFooter)
    if (part.index !== 0) message.id = `${message.id}_${part.index}`
    switch (part.kind) {
      case MessagePartKind.TEXT: {
        message.text = part.text
        message.textAttributes = part.attributes
        break
      }
      case MessagePartKind.ATTACHMENT: {
        // TODO: make this faster if necessary
        const att = attachments.find(a => a.id === part.attachmentID)
        if (att) message.attachments = [att]
        break
      }
      case MessagePartKind.UNSENT: {
        message.isAction = true
        message.parseTemplate = true
        message.editedTimestamp = null
        message.text = '{{sender}} unsent a message'
        break
      }
      default:
    }
    return message
  }).filter(m => m.attachments?.length || m.text || m.textHeading)

  if (addSubjectInline) {
    const firstTextPart = messages[0]
    firstTextPart.text = `${msgRow.subject}\n${firstTextPart.text}`
    const subjectLength = [...msgRow.subject].length
    firstTextPart.textAttributes = {
      entities: [
        {
          from: 0,
          to: subjectLength,
          bold: true,
        },
        ...(firstTextPart.textAttributes?.entities || []).map(e => ({
          ...e,
          from: subjectLength + 1 + e.from,
          to: subjectLength + 1 + e.to,
        })),
      ],
    }
  }

  const firstTextPart = messages.find(msg => typeof msg.text === 'string')
  if (msgRow.associated_message_guid) {
    const m: MessageWithExtra = {
      ...firstTextPart,
      linkedMessageID: msgRow.associated_message_guid.replace(assocMsgGuidPrefix, ''),
    }
    // texts.log('found associated message. first text:', firstTextPart, ' - linked message - ', m.linkedMessageID)
    const assocMsgType = ASSOC_MSG_TYPE[msgRow.associated_message_type]
    let didFail = false
    switch (assocMsgType) {
      case 'sticker':
        if (messages[0]) messages[0].linkedMessageID = m.linkedMessageID
        didFail = true
        break
      case 'heading':
        if (m.text) {
          m.text = m.text
            .replace(RECEIVER_NAME_CONSTANT, m.isSender ? `{{${msgRow.participantID}}}` : `{{${currentUserID}}}`)
            .replace(SENDER_NAME_CONSTANT, m.isSender ? `{{${currentUserID}}}` : `{{${msgRow.participantID}}}`)
        }
        m.parseTemplate = true
        break
      default:
        if (!assocMsgType) {
          didFail = true
          break
        }
        // [un]reacted
        m.isAction = !isSMS // apple imessage has a bug where sms can be reacted to
        // eslint-disable-next-line no-case-declarations
        const [actionType, actionKey] = assocMsgType.split('_', 2) || []
        // eslint-disable-next-line no-case-declarations
        const reactionType = {
          reacted: MessageActionType.MESSAGE_REACTION_CREATED,
          unreacted: MessageActionType.MESSAGE_REACTION_DELETED,
        }[actionType]
        if (!reactionType) break
        m.action = {
          type: reactionType,
          messageID: m.linkedMessageID,
          participantID: m.senderID,
          reactionKey: actionKey,
        }
        if (supportedReactions[actionKey]) {
          m.parseTemplate = true
          m.text = `${msgRow.is_from_me ? 'You' : '{{sender}}'} ${REACTION_VERB_MAP[assocMsgType]} ${msi?.ams ? `"${msi?.ams}"` : 'a message'}`
          m.isHidden = true
        }
    }
    // texts.log('didFail:', didFail)
    if (!didFail) return [m]
  }

  return messages.map(msg => {
    // texts.log('assigning reactions', msg.id, msg.index, reactionRows)
    assignReactions(msg, reactionRows, messages.length === 1 ? null : msg.extra.part, currentUserID)
    return msg
  })
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

export const mapAccountLogin = (al: string) => al?.replace(/^(E|P):/, '')

type Context = {
  currentUserID: string
  handleRowsMap: { [threadID: string]: MappedHandleRow[] }
  mapMessageArgsMap: { [threadID: string]: [MappedMessageRow[], MappedAttachmentRow[], MappedReactionMessageRow[]] }
  threadReadStore: ThreadReadStore | undefined
  unreadChatRowIDs: Set<number>
  dndState: Set<string>
  // todo this shouldnt be optional
  groupImagesMap?: { [attachmentID: string]: string }
}

export function mapMessages(messages: MappedMessageRow[], attachmentRows: MappedAttachmentRow[], reactionRows: MappedReactionMessageRow[], currentUserID: string, addThreadIDs = false): Message[] {
  const groupedAttachmentRows = groupBy(attachmentRows, 'msgRowID')
  const groupedReactionRows = groupBy(reactionRows, r => r.associated_message_guid.replace(assocMsgGuidPrefix, ''))
  return messages
    .flatMap(message => mapMessage(message, groupedAttachmentRows[message.ROWID], groupedReactionRows[message.guid], currentUserID, addThreadIDs))
    .filter(Boolean)
}

export function mapThread(chat: MappedChatRow, context: Context): Thread {
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
  const props = chat.properties ? safeBplistParse(chat.properties) : null
  const isUnreadInSqlite = context.unreadChatRowIDs.has(chat.ROWID)
  const thread: Thread = {
    _original: stringifyWithArrayBuffers([chat, handleRows]),
    id: chat.guid,
    title: chat.display_name,
    imgURL: props?.groupPhotoGuid ? replaceTilde(context.groupImagesMap?.[props?.groupPhotoGuid]) : undefined,
    isUnread: IS_VENTURA_OR_UP
      ? isUnreadInSqlite
      : isUnreadInSqlite && threadReadStore.isThreadUnread(chat.guid, messages[messages.length - 1]?.id),
    // catalina and lower:
    // mutedUntil: props?.ignoreAlertsFlag ? 'forever' : undefined,
    mutedUntil: context.dndState.has(isGroup ? chat.group_id : chat.chat_identifier) ? 'forever' : undefined,
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
    timestamp: fromAppleTime(chat.msgDate),
  }
  if (thread.imgURL) thread.imgURL = url.pathToFileURL(thread.imgURL).href
  return thread
}

export const mapThreads = (chatRows: MappedChatRow[], context: Context) =>
  chatRows.map(chat => mapThread(chat, context))
