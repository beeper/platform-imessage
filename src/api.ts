import { promises as fs } from 'fs'
import os from 'os'
import path from 'path'
import bluebird from 'bluebird'
import { v4 as uuid } from 'uuid'
import { maxBy } from 'lodash'
import { PlatformAPI, OnServerEventCallback, Paginated, Thread, LoginResult, Message, ServerEvent, CurrentUser, InboxName, ServerEventType, ReAuthError, MessageContent, PaginationArg, ActivityType, User, AccountInfo, texts } from '@textshq/platform-sdk'
import { parentPort } from 'worker_threads'

import { mapThreads, mapMessages, mapThread, mapAccountLogin } from './mappers'
import iMessageAPI from './as2'
import ThreadReadStore from './thread-read-store'
// import { trackTime } from '../../common/analytics'
import { IS_BIG_SUR_OR_UP } from './constants'

// @ts-expect-error FIXME
const { AsyncSqlite } = globalThis

const CHAT_DB_PATH = path.join(os.homedir(), 'Library/Messages/chat.db')

const POLL_INTERVAL_MS = 1_000

const THREAD_LIMIT = 50
const MESSAGES_LIMIT = 20

const COMMON_JOINS = `LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
LEFT JOIN handle AS oh ON m.other_handle = oh.ROWID`

const MAP_MESSAGES_COLS = 'm.ROWID AS msgRowID, m.guid AS msgID, m.*, t.guid AS threadID, t.room_name, h.id AS participantID, oh.id AS otherID'

const POLL_MSG_ROWID_COL_INDEX = 0
const POLL_DATE_READ_COL_INDEX = 1
const POLL_THREAD_ID_COL_INDEX = 2

const SQLS = {
  pollMessageCreateUpdate: `SELECT m.ROWID, m.date_read, t.guid, MAX(m.date)
FROM message AS m
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
WHERE m.ROWID > ?
OR m.date_read > ?
GROUP BY t.guid
ORDER BY date DESC`,
  getThreads: (cursorDirection: string) => `SELECT *, (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate
FROM chat
${cursorDirection ? `WHERE msgDate ${cursorDirection} ?` : ''}
ORDER BY msgDate DESC
LIMIT ${THREAD_LIMIT}`,
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
ORDER BY date DESC
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

const MAP_DIRECTION_TO_SQL_OP = {
  after: '>',
  before: '<',
}

async function getDB() {
  try {
    const instance = new AsyncSqlite()
    await instance.init(CHAT_DB_PATH)
    return instance
  } catch (err) { console.error(err) }
}

async function waitForRows(queryFn: () => Promise<any[]>, minRowCount = 1, maxAttempt = 3) {
  let attempt = 0
  let rows = []
  while (attempt++ < maxAttempt && rows.length < minRowCount) {
    rows = await queryFn()
    await bluebird.delay(50)
  }
  return rows
}

export default class AppleiMessage implements PlatformAPI {
  private db: typeof AsyncSqlite & any

  private lastRowID: number = 0

  private lastDateRead: number = 0

  private disposing = false

  private pollTimeout: NodeJS.Timeout

  private currentUserID: string

  private threadReadStore: ThreadReadStore

  private ensureDB = () => {
    if (!this.db) throw new ReAuthError('Unable to connect to iMessage database')
  }

  private createIndexes = () => this.db?.run(SQLS.createIndexes)

  private api = iMessageAPI()

  getCurrentUser = async (): Promise<CurrentUser> => {
    this.ensureDB()
    const logins: any[] = await this.db!.pluck_all(SQLS.getAccountLogins)
    const accounts = logins.map(mapAccountLogin).filter(Boolean)
    this.currentUserID = accounts[0] || 'default'
    return {
      id: this.currentUserID,
      displayText: accounts.join(', '),
    }
  }

  login = async (): Promise<LoginResult> => {
    this.db = await getDB()
    await this.createIndexes()
    if (this.db) return { type: 'success' }
    return { type: 'error', errorMessage: 'Please grant full disk access and try again.' }
  }

  init = async (_: any, { dataDirPath }: AccountInfo) => {
    this.db = await getDB()
    await this.createIndexes()
    this.threadReadStore = new ThreadReadStore(path.dirname(dataDirPath))
  }

  dispose = () => {
    this.disposing = true
    clearTimeout(this.pollTimeout)
    this.api.exit()
    this.db?.dispose()
  }

  private setLastCursorFromRawRows(rows: any[]) {
    if (!rows.length) return
    const maxDateRead = maxBy(rows, POLL_DATE_READ_COL_INDEX)?.[POLL_DATE_READ_COL_INDEX]
    const maxRowID = maxBy(rows, POLL_MSG_ROWID_COL_INDEX)?.[POLL_MSG_ROWID_COL_INDEX]
    if (maxRowID > this.lastRowID) {
      this.lastRowID = maxRowID
    }
    if (maxDateRead > this.lastDateRead) {
      this.lastDateRead = maxDateRead
    }
  }

  private setLastCursor(rows: any[]) {
    if (!rows.length) return
    const maxDateRead = maxBy(rows, 'date_read')?.date_read
    const maxRowID = maxBy(rows, 'msgRowID')?.msgRowID
    if (maxRowID > this.lastRowID) {
      this.lastRowID = maxRowID
    }
    if (maxDateRead > this.lastDateRead) {
      this.lastDateRead = maxDateRead
    }
  }

  subscribeToEvents = (onEvent: OnServerEventCallback): void => {
    this.disposing = false
    let wokeFromSleep = false
    parentPort!.on('message', value => {
      if (typeof value === 'string' && value === 'powermonitor-on-resume') {
        wokeFromSleep = true
      }
    })
    // const debouncedOnEvent = debounce(onEvent, 10_000)
    const pollMessageCreateUpdate = async () => {
      if (this.disposing) return
      if (this.lastRowID && this.lastDateRead) {
        if (wokeFromSleep) {
          console.log('imsg woke from sleep, waiting 10s')
          await bluebird.delay(10_000)
        }
        const rows: any[] = await this.db.raw_all(SQLS.pollMessageCreateUpdate, [this.lastRowID, this.lastDateRead])
        if (texts.IS_DEV) console.log(new Date(), this.lastRowID, this.lastDateRead, 'polling', rows.length)
        const events = rows.map<ServerEvent>(arr => ({ type: ServerEventType.THREAD_MESSAGES_REFRESH, threadID: arr[POLL_THREAD_ID_COL_INDEX] }))
        if (events.length > 0) onEvent(events)
        this.setLastCursorFromRawRows(rows)
        wokeFromSleep = false
      }
      this.pollTimeout = setTimeout(pollMessageCreateUpdate, POLL_INTERVAL_MS)
    }
    pollMessageCreateUpdate()
  }

  searchUsers = (typed: string): User[] => []

  createThread = async (userIDs: string[]) => {
    if (userIDs.length === 0) return null
    this.ensureDB()
    const threadID = await this.api.createThread(userIDs)
    await bluebird.delay(10)
    const [chatRow] = await waitForRows(() => this.db.all(SQLS.getThread, [threadID]), 1)
    if (!chatRow) return
    const handleRows = await waitForRows(() => this.db.all(SQLS.getThreadParticipants, [chatRow.ROWID]), userIDs.length + 1)
    if (handleRows.length > 0) {
      return mapThread(
        chatRow,
        {
          handleRowsMap: { [chatRow.guid]: handleRows },
          currentUserID: this.currentUserID,
          threadReadStore: this.threadReadStore,
        },
      )
    }
  }

  private fetchLastMessageRow = async (threadRowID: string) => {
    const msgRows: any[] = await this.db.all(SQLS.getMessagesWithChatRowID(undefined, 1), [threadRowID])
    const msgRowIDs = msgRows.map(m => m.msgRowID)
    const attachmentRows = msgRows.length ? await this.db.all(SQLS.getAttachments(msgRowIDs), msgRowIDs) : []
    return [msgRows, attachmentRows]
  }

  getThreads = async (inboxName: InboxName, { cursor, direction }: PaginationArg = { cursor: null, direction: null }): Promise<Paginated<Thread>> => {
    if (inboxName !== InboxName.NORMAL) {
      return {
        items: [],
        hasMore: false,
        oldestCursor: null,
      }
    }
    this.ensureDB()
    const chatRows: any[] = await this.db.all(SQLS.getThreads(MAP_DIRECTION_TO_SQL_OP[direction]), cursor ? [+cursor] : [])
    const mapMessageArgsMap: { [threadID: string]: [any[], any[]] } = {}
    const handleRowsMap: { [threadID: string]: any[] } = {}
    const allMsgRows: any[] = []
    const [,, groupImagesRows] = await Promise.all([
      bluebird.map(chatRows, async chatRow => {
        const [msgRows, attachmentRows] = await this.fetchLastMessageRow(chatRow.ROWID)
        allMsgRows.push(...msgRows)
        mapMessageArgsMap[chatRow.guid] = [msgRows, attachmentRows]
      }),
      bluebird.map(chatRows, async chatRow => {
        handleRowsMap[chatRow.guid] = await this.db.all(SQLS.getThreadParticipants, [chatRow.ROWID])
      }),
      IS_BIG_SUR_OR_UP ? this.db.raw_all(SQLS.getGroupImages) : [],
    ])
    const groupImagesMap: { [attachmentID: string]: string } = {};
    (groupImagesRows as [string, string][])?.forEach(([attachmentID, fileName]) => {
      groupImagesMap[attachmentID] = fileName
    })
    const items = mapThreads(chatRows, { mapMessageArgsMap, handleRowsMap, groupImagesMap, currentUserID: this.currentUserID, threadReadStore: this.threadReadStore })
    if (!cursor) this.setLastCursor(allMsgRows)
    return {
      items,
      hasMore: chatRows.length === THREAD_LIMIT,
      oldestCursor: chatRows[chatRows.length - 1]?.msgDate?.toString(),
    }
  }

  getMessages = async (threadID: string, { cursor, direction }: PaginationArg = { cursor: null, direction: null }): Promise<Paginated<Message>> => {
    this.ensureDB()
    const cursorDirection = cursor && MAP_DIRECTION_TO_SQL_OP[direction]
    const msgRows: any[] = await this.db.all(
      SQLS.getMessages(cursorDirection),
      cursor ? [threadID, +cursor] : [threadID],
    )
    msgRows.reverse()
    const msgRowIDs = msgRows.map(m => m.msgRowID)
    const attachmentRows = msgRows.length ? await this.db.all(SQLS.getAttachments(msgRowIDs), msgRowIDs) : []
    const items = mapMessages(msgRows, attachmentRows, this.currentUserID)
    return {
      items,
      hasMore: msgRows.length === MESSAGES_LIMIT,
    }
  }

  searchMessages = async (typed: string, { cursor, direction }: PaginationArg = { cursor: null, direction: null }, threadID?: string): Promise<Paginated<Message>> => {
    this.ensureDB()
    // @ts-expect-error FIXME esnext / webpack / ts-loader issue
    const typedEscaped = `%${typed.replaceAll('%', '\\%')}%`
    const cursorDirection = cursor && MAP_DIRECTION_TO_SQL_OP[direction]
    const bindings = cursor ? [typedEscaped, +cursor] : [typedEscaped]
    if (threadID) bindings.push(threadID)
    const msgRows: any[] = await this.db.all(
      SQLS.searchMessages(cursorDirection, threadID),
      bindings,
    )
    msgRows.reverse()
    const msgRowIDs = msgRows.map(m => m.msgRowID)
    const attachmentRows = msgRows.length ? await this.db.all(SQLS.getAttachments(msgRowIDs), msgRowIDs) : []
    const items = mapMessages(msgRows, attachmentRows, this.currentUserID, true)
    return {
      items,
      hasMore: msgRows.length === MESSAGES_LIMIT,
      oldestCursor: msgRows[0]?.date?.toString(),
    }
  }

  sendMessage = async (threadID: string, content: MessageContent) => {
    if (content.fileBuffer) {
      return this.sendFileFromBuffer(threadID, content.fileBuffer, content.mimeType, content.fileName)
    }
    if (content.filePath) {
      return this.sendFileFromFilePath(threadID, content.filePath)
    }
    return this.sendTextMessage(threadID, content.text)
  }

  private sendTextMessage = async (threadID: string, text: string) => {
    const count = await this.getThreadMessagesCount(threadID)
    await this.api.sendTextMessage(threadID, text)
    let newCount: number = 0
    while (newCount === 0) {
      await bluebird.delay(25)
      newCount = await this.getThreadMessagesCount(threadID) - count
    }
    return true
  }

  private sendFileFromFilePath = async (threadID: string, filePath: string) => {
    const count = await this.getThreadMessagesCount(threadID)
    await this.api.sendFile(threadID, filePath)
    let newCount: number = 0
    while (newCount === 0) {
      await bluebird.delay(25)
      newCount = await this.getThreadMessagesCount(threadID) - count
    }
    return true
  }

  private sendFileFromBuffer = async (threadID: string, fileBuffer: Buffer, mimeType: string, fileName: string) => {
    const tmpFilePath = path.join(os.tmpdir(), fileName || uuid())
    await fs.writeFile(tmpFilePath, fileBuffer)
    const result = await this.sendFileFromFilePath(threadID, tmpFilePath)
    fs.unlink(tmpFilePath).catch(() => {})
    return result
  }

  sendActivityIndicator = (type: ActivityType, threadID: string) => {
    // const userID = threadID.split(';').pop()
    // console.log(userID)
  }

  addReaction = async (threadID: string, messageID: string, reactionKey: string) => { }

  removeReaction = async (threadID: string, messageID: string, reactionKey: string) => { }

  deleteMessage = async (threadID: string, messageID: string) => true

  sendReadReceipt = async (threadID: string, messageID: string) => {
    this.threadReadStore.markThreadRead(threadID, messageID)
    // await this.db.run(SQLS.updateReadTimestamp, [messageCursor, threadID])
  }

  //   private getThreadMessagesChecksum = async (threadID: string, afterCursor: string) => {
  //     const x = await this.db.get(`SELECT count(*) as c
  // FROM message as m
  // ${COMMON_JOINS}
  // WHERE t.guid = ?
  // AND m.date >= ?
  // ORDER BY date DESC`, [threadID, afterCursor])
  //     return x.c
  //   }

  private getThreadMessagesCount = async (threadID: string) => {
    const count = await this.db.pluck_get(SQLS.getMsgCount, threadID)
    return count as number
  }
}
