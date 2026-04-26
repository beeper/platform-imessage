import { groupBy, omit } from 'lodash'

import { stringifyWithArrayBuffers } from './util'
import swiftServer from './SwiftServer/lib'
import type { MappedAttachmentRow, MappedMessageRow, MappedReactionMessageRow } from './types'
import { BeeperMessage } from './desktop-types'

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

function swiftMapMessage(msgRow: MappedMessageRow, attachmentRows: MappedAttachmentRow[] | undefined, reactionRows: MappedReactionMessageRow[] | undefined, currentUserID: string, accountID: string): BeeperMessage[] {
  const inputJSON = stringifyWithArrayBuffers({ msgRow, attachmentRows: attachmentRows ?? [], reactionRows: reactionRows ?? [], currentUserID, accountID })
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

// @ts-expect-error FIXME(skip): argument ordering
// eslint-disable-next-line @typescript-eslint/default-param-last
export function mapMessages(messages: MappedMessageRow[], attachmentRows?: MappedAttachmentRow[], reactionRows?: MappedReactionMessageRow[], currentUserID: string, accountID: string): BeeperMessage[] {
  const groupedAttachmentRows = groupBy(attachmentRows, 'msgRowID')
  const groupedReactionRows = groupBy(reactionRows, r => r.associated_message_guid.replace(assocMsgGuidPrefix, ''))
  return messages
    .flatMap(message => mapMessage(message, groupedAttachmentRows[message.ROWID], groupedReactionRows[message.guid], currentUserID, accountID))
    .filter(Boolean)
}
