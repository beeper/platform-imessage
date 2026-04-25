import { groupBy, omit } from 'lodash'
import { InboxName, Participant, ThreadReminder, texts } from '@textshq/platform-sdk'

import { stringifyWithArrayBuffers } from './util'
import safeBplistParse from './safe-bplist-parse'
import swiftServer from './SwiftServer/lib'
import type { MappedAttachmentRow, MappedChatRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow } from './types'
import { appleDateToMillisSinceEpoch, regularlizeAppleDate } from './time'
import { ThreadArchivalState } from './persistence'
import { BeeperThread, BeeperMessage } from './desktop-types'
import { likelyAlphanumericSenderID } from './heuristics'
import { mapMessageLegacy } from './mappers-legacy'

const IMESSAGE_STRIP_INTERNAL_FIELDS = process.env.IMESSAGE_STRIP_INTERNAL_FIELDS === '1'
const IMESSAGE_SWIFT_MAP_MESSAGE_STRICT = process.env.IMESSAGE_SWIFT_MAP_MESSAGE_STRICT === '1'

const assocMsgGuidPrefix = /^p:([-\d]+)\/|bp:/

const serializeMessageRow = (msgRow: MappedMessageRow) =>
  omit(msgRow, ['attributedBody', 'message_summary_info'])

const SWIFT_DATE_FIELDS = new Set(['timestamp', 'seen', 'editedTimestamp'])

type MapperDiff = {
  path: string
  kind: 'missing-in-swift' | 'missing-in-typescript' | 'type' | 'value' | 'length'
}

const reviveSwiftMapperValue = (value: unknown, key?: string): unknown => {
  if (SWIFT_DATE_FIELDS.has(key ?? '') && typeof value === 'number') return new Date(value)
  if (Array.isArray(value)) return value.map(item => reviveSwiftMapperValue(item))
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([entryKey, entryValue]) => [entryKey, reviveSwiftMapperValue(entryValue, entryKey)]),
    )
  }
  return value
}

const normalizeMapperValue = (value: unknown): unknown => {
  if (value instanceof Date) return { $date: value.getTime() }
  if (Array.isArray(value)) return value.map(normalizeMapperValue)
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key, entryValue]) => key !== '_original' && entryValue !== undefined)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, entryValue]) => [key, normalizeMapperValue(entryValue)]),
    )
  }
  return value
}

const mapperValueType = (value: unknown) =>
  Array.isArray(value) ? 'array' : value === null ? 'null' : typeof value

function diffNormalizedMapperValues(swiftValue: unknown, typescriptValue: unknown, path = '$', diffs: MapperDiff[] = []): MapperDiff[] {
  if (diffs.length >= 20) return diffs
  if (Object.is(swiftValue, typescriptValue)) return diffs

  const swiftType = mapperValueType(swiftValue)
  const typescriptType = mapperValueType(typescriptValue)
  if (swiftType !== typescriptType) {
    diffs.push({ path, kind: 'type' })
    return diffs
  }

  if (Array.isArray(swiftValue) && Array.isArray(typescriptValue)) {
    if (swiftValue.length !== typescriptValue.length) diffs.push({ path, kind: 'length' })
    const length = Math.min(swiftValue.length, typescriptValue.length)
    for (let i = 0; i < length; i++) {
      diffNormalizedMapperValues(swiftValue[i], typescriptValue[i], `${path}[${i}]`, diffs)
    }
    return diffs
  }

  if (swiftValue && typeof swiftValue === 'object' && typescriptValue && typeof typescriptValue === 'object') {
    const swiftRecord = swiftValue as Record<string, unknown>
    const typescriptRecord = typescriptValue as Record<string, unknown>
    const keys = new Set([...Object.keys(swiftRecord), ...Object.keys(typescriptRecord)])
    for (const key of [...keys].sort()) {
      if (diffs.length >= 20) break
      if (!(key in swiftRecord)) {
        diffs.push({ path: `${path}.${key}`, kind: 'missing-in-swift' })
      } else if (!(key in typescriptRecord)) {
        diffs.push({ path: `${path}.${key}`, kind: 'missing-in-typescript' })
      } else {
        diffNormalizedMapperValues(swiftRecord[key], typescriptRecord[key], `${path}.${key}`, diffs)
      }
    }
    return diffs
  }

  diffs.push({ path, kind: 'value' })
  return diffs
}

function projectSwiftToTypescriptShape<T>(swiftValue: T, typescriptValue: unknown): T {
  if (swiftValue instanceof Date || typescriptValue instanceof Date) return swiftValue
  if (Array.isArray(swiftValue) && Array.isArray(typescriptValue)) {
    return swiftValue.map((item, index) => projectSwiftToTypescriptShape(item, typescriptValue[index])) as T
  }
  if (swiftValue && typeof swiftValue === 'object' && typescriptValue && typeof typescriptValue === 'object') {
    const swiftRecord = swiftValue as Record<string, unknown>
    const projected: Record<string, unknown> = {}
    Object.entries(typescriptValue).forEach(([key, value]) => {
      if (key === '_original') return
      if (key in swiftRecord) {
        projected[key] = projectSwiftToTypescriptShape(swiftRecord[key], value)
      } else if (value === undefined) {
        projected[key] = undefined
      }
    })
    return projected as T
  }
  return swiftValue
}

function attachOriginal(messages: BeeperMessage[], msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] | undefined, currentUserID: string) {
  if (IMESSAGE_STRIP_INTERNAL_FIELDS) return messages
  const original = stringifyWithArrayBuffers([serializeMessageRow(msgRow), attachmentRows ?? [], currentUserID])
  messages.forEach(message => {
    message._original = original
  })
  return messages
}

function reportSwiftMapperIssue(kind: 'error' | 'divergence', msgRow: MappedMessageRow, details: string) {
  const message = `iMessage Swift mapMessage ${kind}: guid=${msgRow.guid} thread=${msgRow.threadID} balloon=${msgRow.balloon_bundle_id} ${details}`
  texts.error(message)
  try {
    texts.Sentry.captureMessage(message)
  } catch {
    // ignore reporting failures
  }
}

function swiftMapMessage(msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] = [], reactionRows: MappedReactionMessageRow[] = [], currentUserID: string, accountID: string): BeeperMessage[] {
  const inputJSON = stringifyWithArrayBuffers({ msgRow, attachmentRows, reactionRows, currentUserID, accountID })
  return reviveSwiftMapperValue(JSON.parse(swiftServer.mapMessageJSON(inputJSON))) as BeeperMessage[]
}

export const __mapperParityTest = {
  diffNormalizedMapperValues,
  normalizeMapperValue,
  projectSwiftToTypescriptShape,
  reviveSwiftMapperValue,
}

// eslint-disable-next-line @typescript-eslint/default-param-last -- FIXME(skip)
export function mapMessage(msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] = [], reactionRows: MappedReactionMessageRow[] = [], currentUserID: string, accountID: string): BeeperMessage[] {
  const typescriptMessages = mapMessageLegacy(msgRow, attachmentRows, reactionRows, currentUserID, accountID)
  let swiftMessages: BeeperMessage[]
  try {
    swiftMessages = swiftMapMessage(msgRow, attachmentRows, reactionRows, currentUserID, accountID)
  } catch (error) {
    const message = `error=${error instanceof Error ? error.name : typeof error}`
    if (IMESSAGE_SWIFT_MAP_MESSAGE_STRICT) throw new Error(`Swift mapMessage failed for ${msgRow.guid}: ${message}`)
    reportSwiftMapperIssue('error', msgRow, message)
    return typescriptMessages
  }

  const swiftNormalized = normalizeMapperValue(swiftMessages)
  const typescriptNormalized = normalizeMapperValue(typescriptMessages)
  const diffs = diffNormalizedMapperValues(swiftNormalized, typescriptNormalized)
  if (diffs.length > 0) {
    const details = `diffs=${diffs.map(diff => `${diff.path}:${diff.kind}`).join(',')}`
    if (IMESSAGE_SWIFT_MAP_MESSAGE_STRICT) throw new Error(`Swift mapMessage diverged for ${msgRow.guid}: ${details}`)
    reportSwiftMapperIssue('divergence', msgRow, details)
    return typescriptMessages
  }

  return attachOriginal(
    projectSwiftToTypescriptShape(swiftMessages, typescriptMessages),
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
