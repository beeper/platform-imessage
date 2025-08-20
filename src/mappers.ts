import url from 'url'
import { groupBy, omit } from 'lodash'
import { Message, Participant, Attachment, AttachmentType, MessageActionType, MessageBehavior, Size, MessageReaction, TextAttributes, TextEntity, InboxName, ThreadReminder } from '@textshq/platform-sdk'

import { ASSOC_MSG_TYPE, EXPRESSIVE_MSGS, RECEIVER_NAME_CONSTANT, SENDER_NAME_CONSTANT, AttachmentTransferState, BalloonBundleID, supportedReactions, TMP_MOBILE_SMS_PATH, REACTION_VERB_MAP } from './constants'
import { replaceTilde, stringifyWithArrayBuffers } from './util'
import { getPayloadData, getPayloadProps } from './payload'
import safeBplistParse from './safe-bplist-parse'
import IMAGE_EXTS from './image-exts.json'
import AUDIO_EXTS from './audio-exts.json'
import VIDEO_EXTS from './video-exts.json'
import swiftServer, { Fragment } from './SwiftServer/lib'
import type ThreadReadStore from './thread-read-store'
import type { MappedAttachmentRow, MappedChatRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow, MessageSummaryInfo } from './types'
import { roomFeatures } from './capabilities'
import { AppleDate, appleDateToMillisSinceEpoch, regularlizeAppleDate, unwrapAppleDate } from './time'
import { ThreadArchivalState } from './persistence'
import { BeeperThread, BeeperMessage } from './desktop-types'
import { likelyAlphanumericSenderID } from './heuristics'

const OBJ_REPLACEMENT_CHAR = '\uFFFC' // ￼
const IMSG_EXTENSION_CHAR = '\uFFFD' // �

const assocMsgGuidPrefix = /^p:([-\d]+)\/|bp:/

const associatedTypeIsValid = (type: number): type is keyof typeof ASSOC_MSG_TYPE => Object.keys(ASSOC_MSG_TYPE).includes(String(type))

function mapAttachment(a: MappedAttachmentRow, msgRow: MappedMessageRow): Attachment | null {
  if (a.transfer_state == null) return null
  const { ext, fileName, filePath } = a
  const common = {
    id: a.attachmentID,
    fileName,
    srcURL: filePath,
    loading: a.transfer_state !== AttachmentTransferState.DOWNLOADED,
  } satisfies Partial<Attachment>
  if (filePath) common.srcURL = url.pathToFileURL(filePath).href
  if (IMAGE_EXTS.includes(ext) || ext === 'pluginpayloadattachment') {
    const defaultStickerSize = { height: 100, width: undefined }
    // NOTE(DESK-9043): Beeper Desktop and Texts seem to handle bogus sizes
    // just fine.
    const size: Size = (a.is_sticker ? defaultStickerSize : a.size) as Size
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

function assignReactions(currentUserID: string, message: BeeperMessage, _reactionRows: MappedReactionMessageRow[] = [], filterIndex?: number) {
  const reactions: MessageReaction[] = []
  const reactionRows = filterIndex != null
    ? _reactionRows.filter(r => r.associated_message_guid.startsWith(`p:${filterIndex}/`))
    : _reactionRows
  reactionRows.forEach(reaction => {
    if (!associatedTypeIsValid(reaction.associated_message_type)) return
    const assocMsgType = ASSOC_MSG_TYPE[reaction.associated_message_type]
    if (assocMsgType !== 'sticker' && assocMsgType) {
      const [actionType, actionKey] = assocMsgType.split('_', 2) || []
      const participantID = (reaction.is_from_me || (!reaction.participantID && reaction.handle_id === 0)) ? currentUserID : reaction.participantID
      if (actionType === 'reacted') {
        reactions.push({
          id: participantID,
          reactionKey: actionKey === 'emoji' ? reaction.associated_message_emoji : actionKey,
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

function mapTextEntity(attr: Record<string, string>): Omit<TextEntity, 'from' | 'to'> {
  const entity: Omit<TextEntity, 'from' | 'to'> = {}
  if (attr.__kIMTextBoldAttributeName === '1') entity.bold = true
  if (attr.__kIMTextItalicAttributeName === '1') entity.italic = true
  if (attr.__kIMTextUnderlineAttributeName === '1') entity.underline = true
  if (attr.__kIMTextStrikethroughAttributeName === '1') entity.strikethrough = true
  if (attr.__kIMLinkAttributeName) entity.link = attr.__kIMLinkAttributeName
  if (typeof attr.__kIMMentionConfirmedMention === 'string') entity.mentionedUser = { id: attr.__kIMMentionConfirmedMention }
  return entity
}
function decodeMessageParts(fragments: Fragment[], messageSummaryInfo?: MessageSummaryInfo): MessagePart[] {
  const parts: MessagePart[] = []

  const handledDeletedParts: number[] = []
  let lastSeenPart: number | null = null

  const deletedParts = messageSummaryInfo?.rp

  for (const frag of fragments) {
    const attachmentID = frag.attributes.__kIMFileTransferGUIDAttributeName

    const part: string | null = frag.attributes.__kIMMessagePartAttributeName
    const partNumber: number | null = part != null ? parseInt(part, 10) : null

    if (partNumber != null) {
      // Check for any unsent parts before this one by detecting jumps in the
      // part number relative to the last, and checking if it's present in
      // "rp".
      if (lastSeenPart && partNumber !== lastSeenPart + 1 && deletedParts?.includes(partNumber - 1)) {
        // Calculate how many unsent parts come before this one. If we haven't
        // seen any parts yet, then that means the very first part(s) of the
        // message were deleted. Adjust our math accordingly so we always
        // insert enough unsent parts.
        const unsentParts = partNumber - (lastSeenPart ?? -1) - 1

        // Because we're finding unsent parts that come before this fragment,
        // adjust our starting index (of the first "sent", i.e. not unsent,
        // part).
        const startingIndexOfSent = frag.from + unsentParts

        for (let unsentIndex = startingIndexOfSent - unsentParts; unsentIndex < startingIndexOfSent; unsentIndex++) {
          parts.push({
            kind: MessagePartKind.UNSENT,
            index: parts.length,
            end: unsentIndex + 1,
          })

          // Insert the would-be part index of the deleted part. This value is
          // unused at the moment, but might come in handy in the future.
          const unsentPart = partNumber - (startingIndexOfSent - unsentIndex)
          handledDeletedParts.push(unsentPart)
        }
      }

      lastSeenPart = partNumber
    }

    // By inserting deleted parts into the message, we must update our indexes
    // to account for them.
    const from = frag.from + handledDeletedParts.length
    const end = frag.to + handledDeletedParts.length

    if (typeof attachmentID === 'string') {
      parts.push({
        kind: MessagePartKind.ATTACHMENT,
        index: parts.length,
        end,
        attachmentID,
      })
    } else {
      // The rest of this block (barring the `if` below) continuously updates
      // the last part. Insert a new text part if there's no part attribute,
      // we're on the first part, or the last part wasn't a text one (which
      // means that we can't just update it).
      if (typeof part === 'undefined' || parts.length === 0 || parts.at(-1)?.kind !== MessagePartKind.TEXT) {
        parts.push({
          kind: MessagePartKind.TEXT,
          index: parts.length,
          end: 0, // Continuously updated by the code below.
          text: '',
        })
      }

      const textPart = parts.at(-1) as MessagePartText
      textPart.end = end
      if (frag.text != null) {
        textPart.text += frag.text.replace(IMSG_EXTENSION_CHAR, '')
      }
      const entity = mapTextEntity(frag.attributes)
      if (Object.keys(entity).length > 0) {
        textPart.attributes = {
          entities: [
            ...(textPart.attributes?.entities || []),
            { from, to: end, ...entity },
          ],
        }
      }
    }
  }

  // Because the code above only handles unsent parts that come _before_ each
  // fragment, we never get the ones at the end (because there's no fragment
  // that goes after them). Add them here.
  if (messageSummaryInfo?.rp != null) {
    const trailingUnsentParts = messageSummaryInfo.rp.length - handledDeletedParts.length
    for (let i = 0; i < trailingUnsentParts; i++) {
      parts.push({
        kind: MessagePartKind.UNSENT,
        index: parts.length,
        end: parts.length + 1,
      })
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

const UUID_START = 11
const UUID_LENGTH = 36
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$/i
// eslint-disable-next-line @typescript-eslint/default-param-last -- FIXME(skip)
export function mapMessage(msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] = [], reactionRows: MappedReactionMessageRow[], currentUserID: string): BeeperMessage[] {
  const attachments = attachmentRows.map(a => mapAttachment(a, msgRow)).filter(attachment => attachment != null)
  const isSMS = msgRow.service === 'SMS' || msgRow.service === 'RCS'
  const isGroup = !!msgRow.room_name

  // for whatever reason the date we get back from the db can be `0` instead of
  // `nil`, so be sure to check for that.
  // TODO(skip): perhaps just do this in the database layer
  const dateStringIsTruthy = (date: AppleDate | undefined) =>
    date && unwrapAppleDate(date) !== undefined

  if (msgRow.schedule_type) return []

  const partialMessage: BeeperMessage = {
    _original: stringifyWithArrayBuffers([serializeMessageRow(msgRow), attachmentRows, currentUserID]),
    id: msgRow.guid,
    cursor: msgRow.dateString,

    // TODO(skip): probably throw (or drop) instead of `0`.
    timestamp: regularlizeAppleDate(msgRow.dateString) ?? new Date(0),

    // NOTE(skip): because this object is used as a template of sorts, this
    // means that any additionally synthesized messages will share the same sort
    // key. this might be problematic
    sortKey: appleDateToMillisSinceEpoch(msgRow.dateString) ?? 0,

    senderID: (msgRow.is_from_me || (!msgRow.participantID && msgRow.handle_id === 0)) ? currentUserID : msgRow.participantID,
    // text: (msgRow.subject ? `${msgRow.subject}\n` : '') + (removeObjReplacementChar(msgRow.text) || ''),
    isSender: msgRow.is_from_me === 1,
    isErrored: msgRow.error !== 0,
    isDelivered: msgRow.is_delivered === 1,
    // NOTE(skip): if this is ever implemented for groups (read receipts are
    // possible there when replying), be sure to hash participants
    seen: isGroup ? undefined : regularlizeAppleDate(msgRow.dateReadString),
    threadID: msgRow.threadID,
    extra: {
      // NOTE(skip): Beeper Desktop maintains an incrementing unread count in the
      // renderer when `countsAsUnread` is truthy. Note that `Thread` itself does
      // not track an unread count.
      countsAsUnread: true,
      isSMS: isSMS ? true : undefined,
    },
  }

  if (dateStringIsTruthy(msgRow.dateRetractedString) || msgRow.was_detonated) partialMessage.isDeleted = true
  if (msgRow.is_read) {
    partialMessage.behavior = MessageBehavior.KEEP_READ
  }

  const msi: MessageSummaryInfo | undefined = msgRow.message_summary_info ? safeBplistParse(msgRow.message_summary_info) as MessageSummaryInfo : undefined

  const unsendDataPresent = msi?.otr != null && msi?.rp != null

  // When a message is partially unsent, the edited timestamp reflects when the
  // (ostensibly most recent) unsend occurred. If this is the case, don't show
  // the last unsend timestamp to the user as a last edited timestamp, as that's
  // somewhat misleading.
  if (!unsendDataPresent && dateStringIsTruthy(msgRow.dateRetractedString) && msgRow.dateEditedString) {
    partialMessage.editedTimestamp = regularlizeAppleDate(msgRow.dateEditedString) ?? new Date(0)
  }

  if (msgRow.item_type !== 0) {
    const m: BeeperMessage = {
      ...partialMessage,
      isAction: true,
      parseTemplate: true,
    }
    let didFail = false
    switch (msgRow.item_type) {
      case 1: {
        m.behavior = MessageBehavior.SILENT
        const removed = msgRow.group_action_type === 1
        m.text = removed
          ? `{{sender}} removed {{${msgRow.otherID}}} from the conversation`
          : `{{sender}} added {{${msgRow.otherID}}} to the conversation`
        m.action = {
          type: removed
            ? MessageActionType.THREAD_PARTICIPANTS_REMOVED
            : MessageActionType.THREAD_PARTICIPANTS_ADDED,
          participantIDs: [msgRow.otherID],
          actorParticipantID: m.senderID,
        }
        break
      }
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
        const removedGroupImg = msgRow.group_action_type === 2
        if (changedGroupImg || removedGroupImg) {
          m.text = changedGroupImg
            ? '{{sender}} changed the group photo'
            : '{{sender}} removed the group photo'
          m.attachments = []
          m.action = {
            type: MessageActionType.THREAD_IMG_CHANGED,
            actorParticipantID: m.senderID,
          }
        } else if (msgRow.group_action_type === 0) {
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
  } else {
    partialMessage.extra!.shouldNotify = true
  }

  const partialHeader: Pick<Message, 'textHeading' | 'linkedMessageID'> = {}
  const expressiveSendStyleIsValid = (style: string): style is keyof typeof EXPRESSIVE_MSGS =>
    Object.keys(EXPRESSIVE_MSGS).includes(String(style))
  const expressiveSendStyleID = msgRow.expressive_send_style_id
  const partialFooter: Pick<Message, 'textFooter'> = expressiveSendStyleIsValid(expressiveSendStyleID)
    ? { textFooter: `(Sent with ${(EXPRESSIVE_MSGS[expressiveSendStyleID] || expressiveSendStyleID)} effect)` }
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
  const messages = messageParts.map<BeeperMessage>((part, partIdx) => {
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
        message.editedTimestamp = undefined
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
    const m: BeeperMessage = {
      // fall back to `partialMessage` if no text part was found at all -
      // important to avoid creating a bogus message object with invalid data
      ...(firstTextPart ?? partialMessage),
      linkedMessageID: msgRow.associated_message_guid.replace(assocMsgGuidPrefix, ''),
    }
    // texts.log('found associated message. first text:', firstTextPart, ' - linked message - ', m.linkedMessageID)
    const assocMsgType = associatedTypeIsValid(msgRow.associated_message_type) ? ASSOC_MSG_TYPE[msgRow.associated_message_type] : null
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
        const reactionType = ({
          reacted: MessageActionType.MESSAGE_REACTION_CREATED,
          unreacted: MessageActionType.MESSAGE_REACTION_DELETED,
        } as const)[actionType]
        if (!reactionType) break
        m.action = {
          type: reactionType,
          messageID: m.linkedMessageID,
          participantID: m.senderID,
          reactionKey: actionKey === 'emoji' ? msgRow.associated_message_emoji : actionKey,
        }
        if (actionKey === 'emoji' || actionKey in supportedReactions) {
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
    assignReactions(currentUserID, msg, reactionRows, messages.length === 1 ? undefined : msg.extra?.part)
    return msg
  })
}

function mapParticipant({ participantID: id, uncanonicalized_id }: MappedHandleRow, chatDisplayName?: string): Participant | undefined {
  if (!id) return

  const participant: Participant = { id }

  const isEmail = id.includes('@')
  const isBusiness = id.startsWith('urn:')
  const isPhone = !isBusiness && !isEmail && /\d/.test(id)
  // iMessage can canonicalize SMS shortcodes to contain e.g. `(smsft_rm)` or
  // `(smsft)` at the end. These seemingly aren't a part of the actual SMS
  // shortcode itself, so be sure to prefer the uncanonicalized version when
  // running the heuristic.
  //
  // See: https://www.notion.so/beeper/Canonicalization-Notes-255a168aa37080c189c0d616724830e4?source=copy_link
  const idPreferringUncanonicalized = uncanonicalized_id || id

  if (isBusiness) {
    participant.fullName = chatDisplayName
  } else if (isEmail) {
    participant.email = id
  } else if (isPhone) {
    participant.phoneNumber = id
  } else if (likelyAlphanumericSenderID(idPreferringUncanonicalized)) {
    // Use the `username` field to avoid first/last name splitting treatments
    // and keep the sender ID as-is.
    participant.username = idPreferringUncanonicalized
  }

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
  unreadCounts: Map<number /* chat rowid */, number>
  dndState: Set<string>
  // todo this shouldnt be optional
  chatImagesMap?: { [attachmentID: string]: string }
  reminders?: { [chatGUID: string]: ThreadReminder | undefined }
  archivalStates?: { [chatGUID: string]: ThreadArchivalState | undefined }
  pinStates?: { [chatGUID: string]: boolean | undefined }
}

// @ts-expect-error FIXME(skip): argument ordering
// eslint-disable-next-line @typescript-eslint/default-param-last
export function mapMessages(messages: MappedMessageRow[], attachmentRows?: MappedAttachmentRow[], reactionRows?: MappedReactionMessageRow[], currentUserID: string): BeeperMessage[] {
  const groupedAttachmentRows = groupBy(attachmentRows, 'msgRowID')
  const groupedReactionRows = groupBy(reactionRows, r => r.associated_message_guid.replace(assocMsgGuidPrefix, ''))
  return messages
    .flatMap(message => mapMessage(message, groupedAttachmentRows[message.ROWID], groupedReactionRows[message.guid], currentUserID))
    .filter(Boolean)
}

export function mapThread(chat: MappedChatRow, context: Context): BeeperThread {
  const { currentUserID } = context
  const handleRows = context.handleRowsMap[chat.guid]
  const mapMessageArgs = context.mapMessageArgsMap?.[chat.guid]
  const selfID = chat.last_addressed_handle || mapAccountLogin(chat.account_login) || currentUserID
  const selfParticipant: Participant | undefined = currentUserID === handleRows[0]?.participantID
    ? undefined
    : { ...mapParticipant({ participantID: selfID }), id: currentUserID, isSelf: true }
  const participants = [...handleRows.map(h => mapParticipant(h, chat.display_name)), selfParticipant].filter(participant => participant != null)
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
  const unreadCount = context.unreadCounts.get(chat.ROWID) ?? 0

  const getChatPhotoGuid = (): string | undefined => {
    if (!(typeof props === 'object' && props != null && 'groupPhotoGuid' in props)) return undefined
    const value = props.groupPhotoGuid
    if (typeof value !== 'string') return undefined
    return replaceTilde(context.chatImagesMap?.[value])
  }

  const archivedAt = context.archivalStates?.[chat.guid]?.archivedAt
  const isArchivedUpToOrder = archivedAt ? appleDateToMillisSinceEpoch(archivedAt) : undefined

  const thread: BeeperThread = {
    _original: stringifyWithArrayBuffers([chat, handleRows]),
    id: chat.guid,
    title: chat.display_name,
    imgURL: getChatPhotoGuid(),
    // catalina and lower:
    // mutedUntil: props?.ignoreAlertsFlag ? 'forever' : undefined,
    mutedUntil: context.dndState.has(isGroup ? chat.group_id : chat.chat_identifier) ? 'forever' : undefined,
    type: isGroup ? 'group' : 'single',
    isReadOnly,

    // This mirrors Poller+Unreads.swift.
    unreadCount,
    isMarkedUnread: unreadCount > 0,

    lastReadMessageSortKey: appleDateToMillisSinceEpoch(chat.dateLastMessageReadString),
    messages: {
      hasMore: true,
      items: messages,
    },
    participants: {
      hasMore: false,
      items: participants,
    },
    // NOTE(skip): This works around a bug in PAS's "map missing" plugin where
    // the "folder"/inbox name gets forcibly set to the thread ID.
    folderName: InboxName.NORMAL,
    timestamp: regularlizeAppleDate(chat.msgDateString),
    // @ts-expect-error -- HACK(skip): this exploits the fact that `features` isn't filtered
    // from `assignProps`. this should actually be using `defaultFeatures` once
    // we're able to set our bridge ID properly
    // https://github.com/beeper/beeper-desktop-new/blob/681fe8ea8f23c50cc20d265775eb9a6a3bed5a0f/src/renderer/stores/ThreadStore.ts#L148
    features: roomFeatures,
    reminder: context.reminders?.[chat.guid],
    extra: {
      isArchivedUpToOrder,
      isSMS: (chat.guid.startsWith('SMS;') || chat.guid.startsWith('RCS;')) ? true : undefined,
    },
    isPinned: context.pinStates?.[chat.guid] === true,
  }
  if (thread.imgURL) thread.imgURL = url.pathToFileURL(thread.imgURL).href
  return thread
}

export const mapThreads = (chatRows: MappedChatRow[], context: Context) =>
  chatRows.map(chat => mapThread(chat, context))
