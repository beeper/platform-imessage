import path from 'path'
import { maxBy, memoize } from 'lodash'
import { OnServerEventCallback, texts, IAsyncSqlite, PaginationArg } from '@textshq/platform-sdk'
import { setTimeout as setTimeoutAsync } from 'node:timers/promises'

import { CHAT_DB_PATH, IS_SEQUOIA_OR_UP, IS_VENTURA_OR_UP } from './constants'
import { replaceTilde } from './util'
import { hashThreadID } from './hashing'
import IMAGE_EXTS from './image-exts.json'
import type { ChatRow, MappedAttachmentRow, MappedChatRow, MappedMessageRow, MappedHandleRow, MappedReactionMessageRow } from './types'
import swiftServer from './SwiftServer/lib'

const MAP_DIRECTION_TO_SQL_OP = {
  after: '>',
  before: '<',
} as const

export const THREADS_LIMIT = 25
export const MESSAGES_LIMIT = 20

const MESSAGE_JOINS = `LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
LEFT JOIN handle AS h ON m.handle_id = h.ROWID
LEFT JOIN handle AS oh ON m.other_handle = oh.ROWID`

let MAP_MESSAGES_COLS = `
m.*,
t.guid AS threadID,
t.room_name,
h.id AS participantID,
oh.id AS otherID,

CAST(m.date AS TEXT) AS dateString,
CAST(m.date_read AS TEXT) AS dateReadString,
CAST(m.date_delivered AS TEXT) AS dateDeliveredString`
if (IS_VENTURA_OR_UP) {
  MAP_MESSAGES_COLS += `,
CAST(m.date_edited AS TEXT) AS dateEditedString,
CAST(m.date_retracted AS TEXT) AS dateRetractedString`
}

const dateExpr = (op?: '<' | '>') => (op === '>' && IS_VENTURA_OR_UP ? 'MAX(m.date, COALESCE(m.date_edited, 0))' : 'm.date')

const SQLS = {
  getThreads: (dateComparisonOperator?: '<' | '>') => `SELECT *,
(SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate,
CAST((SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS TEXT) AS msgDateString,
CAST(last_read_message_timestamp AS TEXT) AS dateLastMessageReadString
FROM chat
${dateComparisonOperator ? `WHERE msgDate ${dateComparisonOperator} ?` : ''}
ORDER BY msgDate DESC
LIMIT ${THREADS_LIMIT}`,
  getThread: `SELECT *,
CAST((SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS TEXT) AS msgDateString,
CAST(last_read_message_timestamp AS TEXT) AS dateLastMessageReadString
FROM chat
WHERE chat.guid = ?`,
  getAllThreadGUIDs: 'SELECT guid FROM chat',
  getThreadParticipants: `SELECT uncanonicalized_id, id AS participantID FROM handle
LEFT JOIN chat_handle_join AS chj ON chj.handle_id = handle.ROWID
WHERE chat_id = ?`,
  getChatImageByGUID: 'SELECT filename FROM attachment WHERE guid = ?',

  getAccountLogins: 'SELECT DISTINCT account_login FROM chat',
  createIndexes: IS_VENTURA_OR_UP
    ? 'CREATE INDEX IF NOT EXISTS message_idx_date_read ON message (date_read); CREATE INDEX IF NOT EXISTS message_idx_date_edited ON message (date_edited)'
    : 'CREATE INDEX IF NOT EXISTS message_idx_date_read ON message (date_read)',
  // updateReadTimestamp: 'UPDATE message SET is_read = TRUE WHERE guid = ?',

  getAttachments: (msgIDs: number[]) => `SELECT m.ROWID AS msgRowID, a.filename, a.transfer_name, a.total_bytes, a.is_sticker, a.guid AS attachmentID, a.transfer_state
FROM message AS m
LEFT JOIN message_attachment_join AS maj ON maj.message_id = m.ROWID
LEFT JOIN attachment AS a ON a.ROWID = maj.attachment_id
WHERE m.ROWID IN (${new Array(msgIDs.length).fill('?').join(', ')})`,
  getMessageReactions: (msgGUIDs: string[]) => `SELECT m.ROWID, is_from_me, handle_id, associated_message_type, associated_message_guid, ${IS_SEQUOIA_OR_UP ? 'associated_message_emoji,' : ''} h.id AS participantID
FROM message AS m
LEFT JOIN handle AS h ON m.handle_id = h.ROWID
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
WHERE REPLACE(SUBSTR(associated_message_guid, INSTR(associated_message_guid, '/') + 1), 'bp:', '') IN (${msgGUIDs.map(() => '?').join(',')})
AND chat_id = ?`,
  getMessagesWithChatRowID: (dateComparisonOperator?: '<' | '>', limit = MESSAGES_LIMIT) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${MESSAGE_JOINS}
WHERE cmj.chat_id = ?
${dateComparisonOperator ? `AND ${dateExpr(dateComparisonOperator)} ${dateComparisonOperator} ?` : ''}
ORDER BY date ${dateComparisonOperator === '>' ? 'ASC' : 'DESC'}
LIMIT ${limit}`,
  getMessagesByRowIDs: (rowIDs: number[]) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${MESSAGE_JOINS}
WHERE m.ROWID IN (${new Array(rowIDs.length).fill('?').join(', ')})
ORDER BY date DESC`,
  threadUnreadCount: `SELECT COUNT(m.ROWID)
FROM message AS m
INNER JOIN chat_message_join AS cmj ON m.ROWID = cmj.message_id
WHERE cmj.chat_id = ?
AND m.item_type == 0
AND m.is_read == 0
AND m.is_from_me == 0`,
  getMaxDateRead: 'SELECT MAX(date_read) FROM message',
  getUnreadCounts: `SELECT
  cm.chat_id AS chat_id, COUNT(cm.chat_id) AS unread_count
FROM
  message m
  INNER JOIN chat_message_join cm ON m.ROWID = cm.message_id
WHERE
  m.item_type == 0
  AND m.is_read == 0
  AND m.is_from_me == 0
GROUP BY
  cm.chat_id`,
}

declare const AsyncSqlite: IAsyncSqlite

async function getDB() {
  const instance = new AsyncSqlite()
  await instance.init(CHAT_DB_PATH)
  return instance
}

async function waitForRows<T>(queryFn: () => Promise<T[]>, minRowCount = 1, maxAttempt = 3) {
  let attempt = 0
  let rows: T[] = []
  while (attempt++ < maxAttempt && rows.length < minRowCount) {
    rows = await queryFn()
    await setTimeoutAsync(50)
  }
  return rows
}

export type ChatRef = { type: 'guid', guid: string } | { type: 'rowid', rowid: number }

export default class DatabaseAPI {
  private lastRowID = 0

  private lastDateRead = 0

  private chatGUIDRowIDMap = new Map<string, number>()

  // HACK: this is populated by the `PlatformAPI` subclass, because we need to
  // hand it off to the poller (SwiftServer) in order for it to trigger updates
  eventSender: OnServerEventCallback | null = null

  constructor(private db: IAsyncSqlite) {}

  static async make() {
    texts.log('imsg: creating DatabaseAPI')
    const db = await getDB()
    texts.log('imsg: creating indexes')
    await db.exec(SQLS.createIndexes)
    texts.log('imsg: done creating indexes, returning new DatabaseAPI')
    return new DatabaseAPI(db)
  }

  dispose() {
    swiftServer.cancelPollingIfNecessary()
    return this.db.dispose()
  }

  // this should ideally be fetched from swiftserver
  async getUnreadCounts(): Promise<Map<number /* chat rowid */, number>> {
    const rows = await this.db.all<[], { unread_count: number, chat_id: number }>(SQLS.getUnreadCounts)
    return new Map(rows.map(row => [row.chat_id, row.unread_count]))
  }

  getAccountLogins = (): Promise<string[]> =>
    this.db.pluck_all<void[], string>(SQLS.getAccountLogins)

  private hasAttemptedToStartPoller = false

  async startPollingIfNecessary(maxRowID: number, maxDateRead: number) {
    if (this.hasAttemptedToStartPoller) return
    this.hasAttemptedToStartPoller = true

    // HACK: We only get the callback via `subscribeToEvents`, but we need it
    // synchronously here. Wait until we have the value.
    let spins = 0
    while (!this.eventSender) {
      if (++spins === 50) {
        texts.log("imsg: WARNING: still don't have server event callback after 5 seconds; something is running amok")
      }
      await setTimeoutAsync(100)
    }

    texts.log(`imsg: kicking off poller (max row id: ${maxRowID}, max date read: ${maxDateRead})`)
    // FIXME: it's useless to make these `BigInt`s when they're already `number` (lost precision)
    swiftServer.startPolling(this.eventSender, BigInt(maxRowID), BigInt(maxDateRead))
  }

  async startPollingFromCurrentState() {
    const [lastRowID, maxDateRead] = await Promise.all([
      this.getLastMessageRowID(),
      this.getMaxDateRead(),
    ])
    await this.startPollingIfNecessary(lastRowID, maxDateRead)
  }

  setLastCursor(allMsgRows: MappedMessageRow[]) {
    if (!allMsgRows.length) return
    // FIXME: use columns that don't drop precision
    const maxDateRead = maxBy(allMsgRows, msgRow => {
      const largestSigned64BitInt = '9223372036854775807'
      // Try to guard against bogus read dates. Not sure what causes these to
      // be committed to the database.
      if (msgRow.dateReadString >= largestSigned64BitInt) {
        texts.error(`imsg: detected unreasonably large date_read on message ROWID ${msgRow.ROWID}: ${msgRow.dateReadString}`)
        return 0
      }

      return msgRow.date_read
    })!.date_read
    const maxRowID = maxBy(allMsgRows, 'ROWID')!.ROWID
    if (maxRowID > this.lastRowID) {
      this.lastRowID = maxRowID
    }
    if (maxDateRead > this.lastDateRead) {
      this.lastDateRead = maxDateRead
    }
    this.startPollingIfNecessary(maxRowID, maxDateRead)
  }

  getThreadParticipants = (chatRowID: number): Promise<MappedHandleRow[]> =>
    this.db.all<number[], MappedHandleRow>(SQLS.getThreadParticipants, chatRowID)

  getThreadParticipantsWithWait = (chatRow: ChatRow, userIDs: string[]) =>
    waitForRows(() => this.getThreadParticipants(chatRow.ROWID), userIDs.length + 1)

  async fetchLastMessageRows(chatRowID: number): Promise<[MappedMessageRow[], MappedAttachmentRow[], MappedReactionMessageRow[]]> {
    const msgRow = await this.db.get<number[], MappedMessageRow>(SQLS.getMessagesWithChatRowID(undefined, 1), chatRowID)
    if (!msgRow) return [[], [], []]
    const [attachmentRows, reactionRows] = await Promise.all([
      this.getAttachments([msgRow.ROWID]),
      this.getMessageReactions([msgRow.guid], { type: 'rowid', rowid: chatRowID }),
    ])
    return [[msgRow], attachmentRows, reactionRows]
  }

  async getThread(chatGUID: string): Promise<MappedChatRow> {
    const chat = await this.db.get<string[], MappedChatRow>(SQLS.getThread, chatGUID)
    if (chat) this.chatGUIDRowIDMap.set(chat.guid, chat.ROWID)
    return chat
  }

  private threadHasherWarmed?: Promise<void>

  // loads every chat guid and feeds it through hashThreadID so the Swift
  // hasher's reverse-lookup map is populated for every thread in the db.
  // memoized so repeated misses share a single O(N) pass.
  warmThreadHasher(): Promise<void> {
    this.threadHasherWarmed ??= (async () => {
      const chatGUIDs = await this.db.pluck_all<void[], string>(SQLS.getAllThreadGUIDs)
      chatGUIDs.forEach(hashThreadID)
    })()
    return this.threadHasherWarmed
  }

  private async resolveChatRowID(chatGUID: string): Promise<number> {
    const cached = this.chatGUIDRowIDMap.get(chatGUID)
    if (cached) return cached
    const chatRow = await this.getThread(chatGUID)
    if (!chatRow?.ROWID) throw new Error(`expected chat GUID ${chatGUID} to resolve to a chat row`)
    return chatRow.ROWID
  }

  async isThreadRead(chatGUID: string): Promise<boolean> {
    const rowID = await this.resolveChatRowID(chatGUID)
    return (await this.db.pluck_get<number[], number>(SQLS.threadUnreadCount, rowID)) === 0
  }

  getThreadWithWait = (chatGUID: string) =>
    waitForRows(() => this.getThread(chatGUID).then(c => [c]), 1)

  async getThreads(pagination?: PaginationArg): Promise<MappedChatRow[]> {
    const withCursor = pagination?.cursor ? pagination : undefined
    // FIXME: this shouldn't be parsing to a number due to precision loss
    const chats = await this.db.all<number[], MappedChatRow>(
      SQLS.getThreads(withCursor ? MAP_DIRECTION_TO_SQL_OP[withCursor.direction] : undefined),
      ...(withCursor ? [Number.parseInt(withCursor.cursor, 10)] : []),
    )
    chats.forEach(chat => {
      this.chatGUIDRowIDMap.set(chat.guid, chat.ROWID)
    })
    return chats
  }

  async getChatImageByGUID(attachmentGUID: string): Promise<string | undefined> {
    const fileName = await this.db.pluck_get<string[], string>(SQLS.getChatImageByGUID, attachmentGUID)
    return fileName ? replaceTilde(fileName) : undefined
  }

  getMessagesByRowIDs(rowIDs: number[]): Promise<MappedMessageRow[]> {
    if (rowIDs.length === 0) return Promise.resolve([])
    return this.db.all<number[], MappedMessageRow>(SQLS.getMessagesByRowIDs(rowIDs), ...rowIDs)
  }

  private imageSizeMemoized = memoize(swiftServer.getImageMetadata)

  async getAttachments(msgRowIDs: number[]): Promise<MappedAttachmentRow[]> {
    const attachments = await this.db.all<number[], MappedAttachmentRow>(SQLS.getAttachments(msgRowIDs), ...msgRowIDs)
    return Promise.all(attachments.map(async a => {
      const filePath = replaceTilde(a.filename)
      const { base, ext: _ext } = filePath ? path.parse(filePath) : { base: a.transfer_name, ext: '' }
      const ext = _ext.slice(1).toLowerCase()
      const fileName = a.transfer_name || base
      Object.assign(a, { ext, fileName, filePath })
      if ((IMAGE_EXTS.includes(ext) || ext === 'pluginpayloadattachment')) {
        try {
          const imageSize = await this.imageSizeMemoized(filePath)
          if (!imageSize) {
            texts.error("couldn't determine image size")
            return a
          }
          const { width, height } = imageSize
          if (!width || !height) {
            texts.error('image size had bogus dimensions')
            return a
          }
          a.size = { width, height }
        } catch (err) { texts.error(err) }
      }
      return a
    }))
  }

  async getMessageReactions(msgGUIDs: string[], chat: ChatRef): Promise<MappedReactionMessageRow[]> {
    let chatRowID: number
    if (chat.type === 'guid') {
      chatRowID = await this.resolveChatRowID(chat.guid)
    } else {
      chatRowID = chat.rowid
    }

    const bindings = [...msgGUIDs, chatRowID]
    return this.db.all<typeof bindings, MappedReactionMessageRow>(SQLS.getMessageReactions(msgGUIDs), ...bindings)
  }

  getLastMessageRowID = async (): Promise<number> => {
    const rowID = await this.db.pluck_get<void[], number | null>("select seq from sqlite_sequence where name = 'message'")
    return rowID ?? 0
  }

  getMaxDateRead = async (): Promise<number> => {
    const dateRead = await this.db.pluck_get<void[], number | null>(SQLS.getMaxDateRead)
    return dateRead ?? 0
  }

  getSentMessageIDsSince = (rowID: number): Promise<[number, string][]> =>
    this.db.raw_all<number[], [number, string]>('select ROWID, guid from message where is_from_me = 1 and ROWID > ?', rowID)

  getThreadIDForMessageRowID = (rowID: number): Promise<string> =>
    this.db.pluck_get(`SELECT t.guid
FROM message AS m
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
WHERE m.ROWID = ?`, rowID)

  isNotEmpty = async (): Promise<boolean> =>
    (await this.db.pluck_get<void[], number>('SELECT (SELECT count(*) FROM message) > 0')) === 1

  // async markMessageRead(messageID: string) {
  //   await this.db.run(SQLS.updateReadTimestamp, messageID)
  // }
}
