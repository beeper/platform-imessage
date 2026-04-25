import { groupBy, omit } from 'lodash'
import { InboxName, Participant, ThreadReminder } from '@textshq/platform-sdk'

import { stringifyWithArrayBuffers } from './util'
import safeBplistParse from './safe-bplist-parse'
import swiftServer from './SwiftServer/lib'
import type { MappedAttachmentRow, MappedChatRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow } from './types'
import { appleDateToMillisSinceEpoch, regularlizeAppleDate } from './time'
import { ThreadArchivalState } from './persistence'
import { BeeperThread, BeeperMessage } from './desktop-types'
import { likelyAlphanumericSenderID } from './heuristics'

const IMESSAGE_STRIP_INTERNAL_FIELDS = process.env.IMESSAGE_STRIP_INTERNAL_FIELDS === '1'

const assocMsgGuidPrefix = /^p:([-\d]+)\/|bp:/

const serializeMessageRow = (msgRow: MappedMessageRow) =>
  omit(msgRow, ['attributedBody', 'message_summary_info'])

const SWIFT_DATE_FIELDS = new Set(['timestamp', 'seen', 'editedTimestamp'])

export const reviveSwiftMapperValue = (value: unknown, key?: string): unknown => {
  if (SWIFT_DATE_FIELDS.has(key ?? '') && typeof value === 'number') return new Date(value)
  if (Array.isArray(value)) return value.map(item => reviveSwiftMapperValue(item))
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([entryKey, entryValue]) => [entryKey, reviveSwiftMapperValue(entryValue, entryKey)]),
    )
  }
  return value
}

function attachOriginal(messages: BeeperMessage[], msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] | undefined, currentUserID: string) {
  if (IMESSAGE_STRIP_INTERNAL_FIELDS) return messages
  const original = stringifyWithArrayBuffers([serializeMessageRow(msgRow), attachmentRows ?? [], currentUserID])
  messages.forEach(message => {
    message._original = original
  })
  return messages
}

function swiftMapMessage(msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] = [], reactionRows: MappedReactionMessageRow[] = [], currentUserID: string, accountID: string): BeeperMessage[] {
  const inputJSON = stringifyWithArrayBuffers({ msgRow, attachmentRows, reactionRows, currentUserID, accountID })
  return reviveSwiftMapperValue(JSON.parse(swiftServer.mapMessageJSON(inputJSON))) as BeeperMessage[]
}

// eslint-disable-next-line @typescript-eslint/default-param-last -- FIXME(skip)
export function mapMessage(msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] = [], reactionRows: MappedReactionMessageRow[] = [], currentUserID: string, accountID: string): BeeperMessage[] {
  return attachOriginal(
    swiftMapMessage(msgRow, attachmentRows, reactionRows, currentUserID, accountID),
    msgRow,
    attachmentRows,
    currentUserID,
  )
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
  accountID: string
  currentUserID: string
  handleRowsMap: { [threadID: string]: MappedHandleRow[] }
  mapMessageArgsMap: { [threadID: string]: [MappedMessageRow[], MappedAttachmentRow[], MappedReactionMessageRow[]] }
  unreadCounts: Map<number /* chat rowid */, number>
  dndState: Set<string>
  reminders?: { [chatGUID: string]: ThreadReminder | undefined }
  archivalStates?: { [chatGUID: string]: ThreadArchivalState | undefined }
  pinStates?: { [chatGUID: string]: boolean | undefined }
  lowPriorityStates?: { [chatGUID: string]: boolean | undefined }
}

// @ts-expect-error FIXME(skip): argument ordering
// eslint-disable-next-line @typescript-eslint/default-param-last
export function mapMessages(messages: MappedMessageRow[], attachmentRows?: MappedAttachmentRow[], reactionRows?: MappedReactionMessageRow[], currentUserID: string, accountID: string): BeeperMessage[] {
  const groupedAttachmentRows = groupBy(attachmentRows, 'msgRowID')
  const groupedReactionRows = groupBy(reactionRows, r => r.associated_message_guid.replace(assocMsgGuidPrefix, ''))
  return messages
    .flatMap(message => mapMessage(message, groupedAttachmentRows[message.ROWID], groupedReactionRows[message.guid], currentUserID, accountID))
    .filter(Boolean)
}

export function mapThread(chat: MappedChatRow, context: Context): BeeperThread {
  const { currentUserID, accountID } = context
  const handleRows = context.handleRowsMap[chat.guid]
  const mapMessageArgs = context.mapMessageArgsMap?.[chat.guid]
  const selfID = chat.last_addressed_handle || mapAccountLogin(chat.account_login) || currentUserID
  const selfParticipant: Participant | undefined = currentUserID === handleRows[0]?.participantID
    ? undefined
    : { ...mapParticipant({ participantID: selfID }), id: currentUserID, isSelf: true }
  const participants = [...handleRows.map(h => mapParticipant(h, chat.display_name)), selfParticipant].filter(participant => participant != null)
  const isGroup = !!chat.room_name
  const isReadOnly = chat.state === 0 && chat.properties != null
  const messages = mapMessageArgs ? mapMessages(...mapMessageArgs, currentUserID, accountID) : []
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
    return `asset://${accountID}/thread-image/${value}`
  }

  const archivedAt = context.archivalStates?.[chat.guid]?.archivedAt
  const isArchivedUpToOrder = archivedAt ? appleDateToMillisSinceEpoch(archivedAt) : undefined

  const thread: Omit<BeeperThread, 'isUnread'> = {
    id: chat.guid,
    title: chat.display_name,
    imgURL: getChatPhotoGuid(),
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
    reminder: context.reminders?.[chat.guid],
    extra: {
      isArchivedUpToOrder,
      isSMS: (chat.guid.startsWith('SMS;') || chat.guid.startsWith('RCS;')) ? true : undefined,
    },
    isPinned: context.pinStates?.[chat.guid] === true,
    isLowPriority: context.lowPriorityStates?.[chat.guid] === true,
  }
  if (!IMESSAGE_STRIP_INTERNAL_FIELDS) {
    thread._original = stringifyWithArrayBuffers([chat, handleRows])
  }
  // Desktop computes `isUnread` from `isMarkedUnread || unreadCount > 0`.
  return thread as BeeperThread
}

export const mapThreads = (chatRows: MappedChatRow[], context: Context) =>
  chatRows.map(chat => mapThread(chat, context))
