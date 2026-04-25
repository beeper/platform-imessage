import { Message, MessageID, Paginated, PaginationArg } from '@textshq/platform-sdk'
import { groupBy } from 'lodash'

import { hashMessage } from './hashing'
import type DatabaseAPI from './db-api'
import { MESSAGES_LIMIT } from './db-api'
import { mapMessageLegacy } from './mappers-legacy'
import type { MappedAttachmentRow, MappedMessageRow, MappedReactionMessageRow } from './types'

const assocMsgGuidPrefix = /^p:([-\d]+)\/|bp:/

function mapMessagesLegacy(
  messages: MappedMessageRow[],
  attachmentRows: MappedAttachmentRow[],
  reactionRows: MappedReactionMessageRow[],
  currentUserID: string,
  accountID: string,
) {
  const groupedAttachmentRows = groupBy(attachmentRows, 'msgRowID')
  const groupedReactionRows = groupBy(reactionRows, r => r.associated_message_guid.replace(assocMsgGuidPrefix, ''))
  return messages
    .flatMap(message => mapMessageLegacy(message, groupedAttachmentRows[message.ROWID], groupedReactionRows[message.guid], currentUserID, accountID))
    .filter(Boolean)
}

// Temporary TypeScript source-of-truth for getMessage/getMessages. Delete this
// file once the Swift implementation has baked enough that the parity guard can
// be removed.
export async function getMessagesLegacy(
  db: DatabaseAPI,
  threadID: string,
  pagination: PaginationArg | undefined,
  currentUserID: string,
  accountID: string,
): Promise<Paginated<Message>> {
  const msgRows = await db.getMessages(threadID, pagination)
  if (pagination?.direction !== 'after') msgRows.reverse()
  const msgRowIDs = msgRows.map(m => m.ROWID)
  const msgGUIDs = msgRows.map(m => m.guid)
  const [attachmentRows, reactionRows] = msgRows.length === 0 ? [[], []] : await Promise.all([
    db.getAttachments(msgRowIDs),
    db.getMessageReactions(msgGUIDs, { type: 'guid', guid: threadID }),
  ])
  const items = mapMessagesLegacy(msgRows, attachmentRows, reactionRows, currentUserID, accountID)
  return {
    // NOTE(types): appease typescript, but we aren't actually using the texts SDK contract
    items: items.map(hashMessage) as Message[],
    hasMore: msgRows.length === MESSAGES_LIMIT,
  }
}

export async function getMessageLegacy(
  db: DatabaseAPI,
  threadID: string,
  messageID: MessageID,
  currentUserID: string,
  accountID: string,
): Promise<Message | undefined> {
  const [messageGUID] = messageID.split('_')
  const msgRow = await db.getMessage(messageGUID)
  if (!msgRow) return
  const [attachmentRows, reactionRows] = await Promise.all([
    db.getAttachments([msgRow.ROWID]),
    db.getMessageReactions([msgRow.guid], { type: 'guid', guid: threadID }),
  ])
  const items = mapMessagesLegacy([msgRow], attachmentRows, reactionRows, currentUserID, accountID)
  const message = items.find(i => i.id === messageID)
  // NOTE(types): appease typescript, but we aren't actually using the texts SDK contract
  return (message ? hashMessage(message) : message) as Message | undefined
}
