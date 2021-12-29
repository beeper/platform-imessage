import { groupBy, omit, truncate, findLast } from 'lodash'
import { Thread, Message, Participant, MessageAttachment, MessageAttachmentType, MessageActionType, MessageBehavior, Size, MessageReaction, TextAttributes, texts } from '@textshq/platform-sdk'

import { ASSOC_MSG_TYPE, EXPRESSIVE_MSGS, RECEIVER_NAME_CONSTANT, SENDER_NAME_CONSTANT, AttachmentTransferState, BalloonBundleID, supportedReactions } from './constants'
import { fromAppleTime, replaceTilde, stringifyWithArrayBuffers } from './util'
import { getPayloadData, getPayloadProps } from './payload'
import safeBplitParse from './safe-bplist-parse'
import IMAGE_EXTS from './image-exts.json'
import AUDIO_EXTS from './audio-exts.json'
import VIDEO_EXTS from './video-exts.json'
import swiftServer, { Fragment } from './SwiftServer/lib'
import type ThreadReadStore from './thread-read-store'
import type { MappedAttachmentRow, MappedChatRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow } from './types'

const OBJ_REPLACEMENT_CHAR = '\uFFFC' // ￼
const IMSG_EXTENSION_CHAR = '\uFFFD' // �

const assocMsgGuidPrefix = /^p:([-\d]+)\/|bp:/
const whitespaceRegexGlobal = /\s+/g

function mapAttachment(a: MappedAttachmentRow): MessageAttachment {
  if (a.transfer_state == null) return
  const { ext, fileName, filePath } = a
  const common = {
    id: a.attachmentID,
    fileName,
    srcURL: filePath,
    loading: a.transfer_state !== AttachmentTransferState.DOWNLOADED,
  }
  if (filePath) common.srcURL = 'file://' + encodeURI(filePath)
  if (IMAGE_EXTS.includes(ext) || ext === 'pluginpayloadattachment') {
    const size: Size = a.is_sticker ? { height: 80, width: undefined } : a.size
    if (ext === 'png') {
      common.srcURL = 'asset://$accountID/' + Buffer.from(filePath).toString('hex')
    }
    return { ...common, type: MessageAttachmentType.IMG, size }
  }
  if (VIDEO_EXTS.includes(ext)) {
    return { ...common, type: MessageAttachmentType.VIDEO }
  }
  if (AUDIO_EXTS.includes(ext)) {
    return { ...common, type: MessageAttachmentType.AUDIO }
  }
  return { ...common, type: MessageAttachmentType.UNKNOWN }
}

const serializeMessageRow = (msgRow: MappedMessageRow) =>
  omit(msgRow, ['attributedBody', 'message_summary_info'])

const removeObjReplacementChar = (text: string): string => {
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

interface MessagePartText {
  kind: 'TEXT'
  index: number
  text: string
  end: number
  attributes?: TextAttributes
}

interface MessagePartAttachment {
  kind: 'ATTACHMENT'
  index: number
  end: number
  attachmentID: string
}

type MessagePart = MessagePartText | MessagePartAttachment

function decodeMessageParts(fragments: Fragment[]): MessagePart[] {
  const parts: MessagePart[] = []
  // eslint-disable-next-line no-restricted-syntax
  for (const frag of fragments) {
    const attachmentID = frag.attributes.__kIMFileTransferGUIDAttributeName
    if (typeof attachmentID === 'string') {
      parts.push({
        kind: 'ATTACHMENT',
        index: parts.length,
        end: frag.to,
        attachmentID,
      })
    } else {
      const partStr = frag.attributes.__kIMMessagePartAttributeName
      if (typeof partStr === 'undefined' || +partStr !== parts.length - 1) {
        parts.push({
          kind: 'TEXT',
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
    if (part.kind !== 'TEXT') continue
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

export function mapMessage(msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] = [], reactionRows: MappedReactionMessageRow[], currentUserID: string, addThreadIDs = false): MessageWithExtra[] {
  if (msgRow.was_data_detected === 0) return
  const attachments = attachmentRows.map(mapAttachment).filter(Boolean)
  const isSMS = msgRow.service === 'SMS'
  const isGroup = !!msgRow.room_name

  const partialMessage: MessageWithExtra = {
    _original: stringifyWithArrayBuffers([serializeMessageRow(msgRow), attachmentRows, currentUserID]),
    id: msgRow.msgID,
    cursor: msgRow.date.toString(),
    timestamp: fromAppleTime(msgRow.date),
    senderID: (msgRow.is_from_me || (!msgRow.participantID && msgRow.handle_id === 0)) ? currentUserID : msgRow.participantID,
    // text: (msgRow.subject ? `${msgRow.subject}\n` : '') + (removeObjReplacementChar(msgRow.text) || ''),
    isSender: msgRow.is_from_me === 1,
    isErrored: msgRow.error !== 0,
    isDelivered: true, // msgRow.is_delivered === 1,
    seen: isGroup ? undefined : fromAppleTime(msgRow.date_read),
    extra: {},
  }

  if (isSMS) partialMessage.extra.isSMS = true
  if (addThreadIDs) partialMessage.threadID = msgRow.threadID
  if (msgRow.is_read) {
    partialMessage.behavior = MessageBehavior.KEEP_READ
  }

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

  const partialHeader: Partial<MessageWithExtra> = {}

  const partialFooter: Partial<MessageWithExtra> = {
    textFooter: msgRow.expressive_send_style_id
      ? `(Sent with ${(EXPRESSIVE_MSGS[msgRow.expressive_send_style_id] || msgRow.expressive_send_style_id)} effect)`
      : undefined,
  }

  const payloadData = getPayloadData(msgRow)
  Object.assign(partialMessage, getPayloadProps(payloadData, attachments, msgRow.balloon_bundle_id))

  if (msgRow.balloon_bundle_id === BalloonBundleID.DIGITAL_TOUCH) {
    partialHeader.textHeading = 'Digital Touch Message'
  } else if (msgRow.balloon_bundle_id === BalloonBundleID.HANDWRITING) {
    partialHeader.textHeading = 'Handwritten Message'
  } else if (msgRow.balloon_bundle_id === BalloonBundleID.BIZ_EXTENSION) {
    partialHeader.textHeading = 'Business Chat Extension'
    // TODO: Handle busines chats
    // if (m.attachments[0]) m.attachments[0].size = { height: 80, width: 80 }
  }

  // {
  //   "amc" => 0
  //   "amsa" => "com.apple.siri"
  //   "ust" => 1
  // }
  if (msgRow.message_summary_info) {
    const msi = safeBplitParse(Buffer.from(msgRow.message_summary_info))
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
    let partIndex = msgRow.thread_originator_part?.split(':')?.[0]
    if (partIndex === '0') partIndex = ''
    if (partIndex === '18446744073709551615') partIndex = '-1'
    partialHeader.linkedMessageID = msgRow.thread_originator_guid + (partIndex ? `_${partIndex}` : '')
  }

  let messageParts: MessagePart[] = []
  if (swiftServer && msgRow.attributedBody) {
    const attributes = swiftServer.decodeAttributedString(msgRow.attributedBody)
    if (attributes) {
      messageParts = decodeMessageParts(attributes)
    }
  }
  if (messageParts.length === 0) {
    messageParts = [{
      kind: 'TEXT',
      index: 0,
      // @ts-expect-error fix after changing es target
      text: removeObjReplacementChar(msgRow.text || '').replaceAll(IMSG_EXTENSION_CHAR, ''),
    } as MessagePart].concat(...(attachments.map((a, i) => ({
      kind: 'ATTACHMENT',
      attachmentID: a.id,
      index: i + 1,
    })) as MessagePartAttachment[]))
  }

  const addSubjectInline = msgRow.subject && messageParts[0].kind === 'TEXT' && messageParts[0].text.length
  if (msgRow.subject && !addSubjectInline) {
    messageParts.unshift({
      kind: 'TEXT',
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
    if (part.kind === 'TEXT') {
      message.text = part.text
      message.textAttributes = part.attributes
    } else if (part.kind === 'ATTACHMENT') {
      // TODO: make this faster if necessary
      const att = attachments.find(a => a.id === part.attachmentID)
      if (att) message.attachments = [att]
    }
    return message
  }).filter(m => m.attachments?.length || m.text?.length)

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
        m.text = m.text
          .replace(RECEIVER_NAME_CONSTANT, m.isSender ? `{{${msgRow.participantID}}}` : `{{${currentUserID}}}`)
          .replace(SENDER_NAME_CONSTANT, m.isSender ? `{{${currentUserID}}}` : `{{${msgRow.participantID}}}`)
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
          // todo fix for localized reaction messages
          m.text = `{{sender}}: ${truncate(m.text.replace(whitespaceRegexGlobal, ' '), { length: 50 })}`
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

export const mapAccountLogin = (al: string) => al?.replace(/^E:/, '')

type Context = {
  currentUserID: string
  handleRowsMap: { [threadID: string]: MappedHandleRow[] }
  mapMessageArgsMap: { [threadID: string]: [MappedMessageRow[], MappedAttachmentRow[], MappedReactionMessageRow[]] }
  threadReadStore: ThreadReadStore
  dndState: Set<string>
  // todo this shouldnt be optional
  groupImagesMap?: { [attachmentID: string]: string }
}

export function mapMessages(messages: MappedMessageRow[], attachmentRows: MappedAttachmentRow[], reactionRows: MappedReactionMessageRow[], currentUserID: string, addThreadIDs = false): Message[] {
  const groupedAttachmentRows = groupBy(attachmentRows, 'msgRowID')
  const groupedReactionRows = groupBy(reactionRows, r => r.associated_message_guid.replace(assocMsgGuidPrefix, ''))
  return messages
    .flatMap(message => mapMessage(message, groupedAttachmentRows[message.msgRowID], groupedReactionRows[message.guid], currentUserID, addThreadIDs))
    .filter(Boolean)
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
  const lastNonActionReceivedMessage = messageRows ? findLast(messageRows, r => r.item_type === 0 && r.is_from_me === 0) : undefined
  const isUnreadInSqlite = lastNonActionReceivedMessage?.is_read === 0
  const thread: Thread = {
    _original: stringifyWithArrayBuffers([chat, handleRows]),
    id: chat.guid,
    title: chat.display_name,
    imgURL: props?.groupPhotoGuid ? replaceTilde(context.groupImagesMap?.[props?.groupPhotoGuid]) : undefined,
    isUnread: isUnreadInSqlite && threadReadStore.isThreadUnread(chat.guid, messages[messages.length - 1]?.id),
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
    timestamp: fromAppleTime(chat.msgDate) || new Date(),
  }
  if (thread.imgURL) thread.imgURL = 'file://' + encodeURI(thread.imgURL)
  return thread
}

export const mapThreads = (chatRows: MappedChatRow[], context: Context) =>
  chatRows.map(chat => mapThread(chat, context))
