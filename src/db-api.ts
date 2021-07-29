import bluebird from 'bluebird'
import { maxBy } from 'lodash'
// import { parentPort } from 'worker_threads'
import { OnServerEventCallback, ServerEvent, ServerEventType } from '@textshq/platform-sdk'

import { CHAT_DB_PATH } from './constants'
import spawnRustServer from './rust-server'
import type { ChatRow, MappedAttachmentRow, MappedChatRow, MappedMessageRow } from './types'

const MAP_DIRECTION_TO_SQL_OP = {
  after: '>',
  before: '<',
}

export const THREADS_LIMIT = 30
export const MESSAGES_LIMIT = 20

const COMMON_JOINS = `LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
LEFT JOIN handle AS oh ON m.other_handle = oh.ROWID`

const MAP_MESSAGES_COLS = 'm.ROWID AS msgRowID, m.guid AS msgID, m.*, t.guid AS threadID, t.room_name, h.id AS participantID, oh.id AS otherID'

const SQLS = {
  getThreads: (cursorDirection: string) => `SELECT *, (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate
FROM chat
${cursorDirection ? `WHERE msgDate ${cursorDirection} ?` : ''}
ORDER BY msgDate DESC
LIMIT ${THREADS_LIMIT}`,
  getThreadParticipants: `SELECT uncanonicalized_id, id AS participantID FROM handle
LEFT JOIN chat_handle_join AS chj ON chj.handle_id = handle.ROWID
WHERE chat_id = ?`,
  getThread: 'SELECT * FROM chat WHERE chat.guid = ?',
  getGroupImages: "SELECT guid,filename FROM attachment WHERE transfer_name = 'GroupPhotoImage'",
  getMessages: (cursorDirection: string, limit = MESSAGES_LIMIT) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${COMMON_JOINS}
LEFT JOIN handle AS h ON m.handle_id = h.ROWID
WHERE t.guid = ?
${cursorDirection ? `AND m.date ${cursorDirection} ?` : ''}
ORDER BY date ${cursorDirection === '>' ? 'ASC' : 'DESC'}
LIMIT ${limit}`,
  getMessagesWithChatRowID: (cursorDirection: string, limit = MESSAGES_LIMIT) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${COMMON_JOINS}
LEFT JOIN handle AS h ON m.handle_id = h.ROWID
WHERE cmj.chat_id = ?
${cursorDirection ? `AND m.date ${cursorDirection} ?` : ''}
ORDER BY date DESC
LIMIT ${limit}`,
  searchMessages: (cursorDirection: string, threadID?: string) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${COMMON_JOINS}
LEFT JOIN handle AS h ON m.handle_id = h.ROWID
WHERE m.text LIKE ? ESCAPE '\\' COLLATE NOCASE
${cursorDirection ? `AND m.date ${cursorDirection} ?` : ''}
${threadID ? 'AND t.guid = ?' : ''}
ORDER BY date DESC
LIMIT ${MESSAGES_LIMIT}`,
  getAttachments: (msgIDs: number[]) => `SELECT m.ROWID AS msgRowID, a.filename, a.transfer_name, a.is_sticker, a.guid AS attachmentID, a.transfer_state
FROM message AS m
LEFT JOIN message_attachment_join AS maj ON maj.message_id = m.ROWID
LEFT JOIN attachment AS a ON a.ROWID = maj.attachment_id
WHERE m.ROWID IN (${msgIDs.map(_ => '?').join(', ')})`,
  getAccountLogins: 'SELECT DISTINCT account_login FROM chat',
  getMsgCount: `SELECT count(*)
FROM message AS m
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
WHERE t.guid = ?`,
  createIndexes: 'CREATE INDEX IF NOT EXISTS message_idx_date_read ON message (date_read)',
  // updateReadTimestamp: 'update chat set last_read_message_timestamp = ? where guid = ?',
}

// @ts-expect-error FIXME
const { AsyncSqlite } = globalThis

async function getDB() {
  try {
    const instance = new AsyncSqlite()
    await instance.init(CHAT_DB_PATH)
    return instance
  } catch (err) { console.error(err) }
}

async function waitForRows<T>(queryFn: () => Promise<T[]>, minRowCount = 1, maxAttempt = 3) {
  let attempt = 0
  let rows = []
  while (attempt++ < maxAttempt && rows.length < minRowCount) {
    rows = await queryFn()
    await bluebird.delay(50)
  }
  return rows
}

export default class DatabaseAPI {
  private db: typeof AsyncSqlite & any

  private lastRowID = 0

  private lastDateRead = 0

  private eventQueue: ServerEvent[] = []

  private onEvent: OnServerEventCallback = events => {
    this.eventQueue.push(...events)
  }

  private rustServer: ReturnType<typeof spawnRustServer>

  private readonly onRustServerMessage = (data: any) => {
    if (!data?.threads) return console.error('unknown message from rust_server')
    const threadIDs = data.threads as string[]
    const events = threadIDs.map<ServerEvent>(threadID => ({ type: ServerEventType.THREAD_MESSAGES_REFRESH, threadID }))
    if (events.length > 0) this.onEvent(events)
  }

  async init() {
    this.db = await getDB()
    await this.db?.run(SQLS.createIndexes)
    this.rustServer = spawnRustServer(this.onRustServerMessage)
  }

  get connected() {
    return !!this.db
  }

  dispose() {
    this.rustServer?.exit()
    return this.db?.dispose()
  }

  getAccountLogins(): Promise<string[]> {
    return this.db!.pluck_all(SQLS.getAccountLogins)
  }

  private calledRustServerSetOnce = false

  async updateRustServer(args: number[]) {
    if (this.calledRustServerSetOnce) return
    this.calledRustServerSetOnce = true
    while (!this.rustServer) {
      await bluebird.delay(10)
    }
    this.rustServer!.send({ method: 'start_polling', args })
  }

  setLastCursor(rows: any[]) {
    if (!rows.length) return
    const maxDateRead = maxBy(rows, 'date_read')?.date_read
    const maxRowID = maxBy(rows, 'msgRowID')?.msgRowID
    if (maxRowID > this.lastRowID) {
      this.lastRowID = maxRowID
    }
    if (maxDateRead > this.lastDateRead) {
      this.lastDateRead = maxDateRead
    }
    this.updateRustServer([maxRowID, maxDateRead])
  }

  startPolling(onEvent: OnServerEventCallback) {
    this.onEvent(this.eventQueue)
    this.onEvent = onEvent
    // let wokeFromSleep = false
    // parentPort!.on('message', value => {
    //   if (typeof value === 'string' && value === 'powermonitor-on-resume') {
    //     wokeFromSleep = true
    //   }
    // })
  }

  getThread(threadID: string): Promise<ChatRow[]> {
    return this.db.all(SQLS.getThread, [threadID])
  }

  getThreadWithWait(threadID: string) {
    return waitForRows(() => this.getThread(threadID), 1)
  }

  getThreadParticipants(chatRowID: number): Promise<any[]> {
    return this.db.all(SQLS.getThreadParticipants, [chatRowID])
  }

  getThreadParticipantsWithWait(chatRow: ChatRow, userIDs: string[]) {
    return waitForRows(() => this.getThreadParticipants(chatRow.ROWID), userIDs.length + 1)
  }

  async fetchLastMessageRows(threadRowID: number) {
    const msgRows: MappedMessageRow[] = await this.db.all(SQLS.getMessagesWithChatRowID(undefined, 5), [threadRowID])
    msgRows.reverse()
    const msgRowIDs = msgRows.map(m => m.msgRowID)
    const attachmentRows = msgRows.length ? await this.db.all(SQLS.getAttachments(msgRowIDs), msgRowIDs) : []
    return [msgRows, attachmentRows]
  }

  getThreads(cursor: string, direction: 'after' | 'before'): Promise<MappedChatRow[]> {
    return this.db.all(SQLS.getThreads(MAP_DIRECTION_TO_SQL_OP[direction]), cursor ? [+cursor] : [])
  }

  getGroupImages(): Promise<any[]> {
    return this.db.raw_all(SQLS.getGroupImages)
  }

  getMessages(threadID: string, cursor: string, direction: 'after' | 'before'): Promise<MappedMessageRow[]> {
    const cursorDirection = cursor && MAP_DIRECTION_TO_SQL_OP[direction]
    return this.db.all(
      SQLS.getMessages(cursorDirection),
      cursor ? [threadID, +cursor] : [threadID],
    )
  }

  getAttachments(msgRowIDs: number[]): Promise<MappedAttachmentRow[]> {
    return this.db.all(SQLS.getAttachments(msgRowIDs), msgRowIDs)
  }

  async searchMessages(typed: string, threadID: string, cursor: string, direction: string) {
    // @ts-expect-error replaceAll
    const typedEscaped = `%${typed.replaceAll('%', '\\%')}%`
    const cursorDirection = cursor && MAP_DIRECTION_TO_SQL_OP[direction]
    const bindings = cursor ? [typedEscaped, +cursor] : [typedEscaped]
    if (threadID) bindings.push(threadID)
    const msgRows: MappedMessageRow[] = await this.db.all(
      SQLS.searchMessages(cursorDirection, threadID),
      bindings,
    )
    msgRows.reverse()
    return msgRows
  }

  getThreadMessagesCount(threadID: string): Promise<number> {
    return this.db.pluck_get(SQLS.getMsgCount, threadID)
  }
}
