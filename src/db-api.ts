import path from 'path'
import bluebird, { promisify } from 'bluebird'
import { maxBy, memoize, findIndex, findLastIndex } from 'lodash'
// import { parentPort } from 'worker_threads'
import imageSizeSync from 'image-size'
import { Message, OnServerEventCallback, ServerEvent, texts } from '@textshq/platform-sdk'

import { CHAT_DB_PATH } from './constants'
import { Server as RustServer } from './RustServer/lib'
import { replaceTilde } from './util'
import { mapMessage, mapMessages } from './mappers'
import IMAGE_EXTS from './image-exts.json'
import type { ChatRow, MappedAttachmentRow, MappedChatRow, MappedMessageRow, MappedHandleRow, MappedReactionMessageRow } from './types'
import type PAPI from './api'

const imageSizeAsync = promisify(imageSizeSync)

const MAP_DIRECTION_TO_SQL_OP = {
  after: '>',
  before: '<',
}

export const THREADS_LIMIT = 25
export const MESSAGES_LIMIT = 20

const MESSAGE_JOINS = `LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
LEFT JOIN handle AS h ON m.handle_id = h.ROWID
LEFT JOIN handle AS oh ON m.other_handle = oh.ROWID`

const MAP_MESSAGES_COLS = 'm.ROWID AS msgRowID, m.guid AS msgID, m.*, t.guid AS threadID, t.room_name, h.id AS participantID, oh.id AS otherID'

const SQLS = {
  getThreads: (cursorDirection: string) => `SELECT *, (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate
FROM chat
${cursorDirection ? `WHERE msgDate ${cursorDirection} ?` : ''}
ORDER BY msgDate DESC
LIMIT ${THREADS_LIMIT}`,
  getThread: `SELECT *, (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = chat.ROWID) AS msgDate
FROM chat
WHERE chat.guid = ?`,
  getThreadParticipants: `SELECT uncanonicalized_id, id AS participantID FROM handle
LEFT JOIN chat_handle_join AS chj ON chj.handle_id = handle.ROWID
WHERE chat_id = ?`,
  getGroupImages: "SELECT guid,filename FROM attachment WHERE transfer_name = 'GroupPhotoImage'",

  getAccountLogins: 'SELECT DISTINCT account_login FROM chat',
  getMsgCount: `SELECT count(*)
FROM message AS m
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
WHERE t.guid = ?`,
  createIndexes: 'CREATE INDEX IF NOT EXISTS message_idx_date_read ON message (date_read)',
  // updateReadTimestamp: 'UPDATE message SET is_read = TRUE WHERE guid = ?',

  getAttachments: (msgIDs: number[]) => `SELECT m.ROWID AS msgRowID, a.filename, a.transfer_name, a.is_sticker, a.guid AS attachmentID, a.transfer_state
FROM message AS m
LEFT JOIN message_attachment_join AS maj ON maj.message_id = m.ROWID
LEFT JOIN attachment AS a ON a.ROWID = maj.attachment_id
WHERE m.ROWID IN (${msgIDs.map(_ => '?').join(', ')})`,
  getMessageReactions: (msgGUIDs: string[]) => `SELECT is_from_me, handle_id, associated_message_type, associated_message_guid, h.id AS participantID
FROM message AS m
LEFT JOIN handle AS h ON m.handle_id = h.ROWID
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
WHERE REPLACE(SUBSTR(associated_message_guid, INSTR(associated_message_guid, '/') + 1), 'bp:', '') IN (${msgGUIDs.map(() => '?').join(',')})
AND chat_id = ?`,
  getMessagesWithChatRowID: (cursorDirection: string, limit = MESSAGES_LIMIT) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${MESSAGE_JOINS}
WHERE cmj.chat_id = ?
${cursorDirection ? `AND m.date ${cursorDirection} ?` : ''}
ORDER BY date ${cursorDirection === '>' ? 'ASC' : 'DESC'}
LIMIT ${limit}`,
  getMessages: (cursorDirection: string, limit = MESSAGES_LIMIT) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${MESSAGE_JOINS}
WHERE t.guid = ?
${cursorDirection ? `AND m.date ${cursorDirection} ?` : ''}
ORDER BY date ${cursorDirection === '>' ? 'ASC' : 'DESC'}
LIMIT ${limit}`,
  searchMessages: (cursorDirection: string, chatGUID?: string) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${MESSAGE_JOINS}
WHERE m.text LIKE ? ESCAPE '\\' COLLATE NOCASE
${cursorDirection ? `AND m.date ${cursorDirection} ?` : ''}
${chatGUID ? 'AND t.guid = ?' : ''}
ORDER BY date ${cursorDirection === '>' ? 'ASC' : 'DESC'}
LIMIT ${MESSAGES_LIMIT}`,
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
  let rows: T[] = []
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

  private chatGUIDRowIDMap = new Map<string, number>()

  private rustServer: RustServer

  constructor(private readonly papi: InstanceType<typeof PAPI>) {}

  async init() {
    this.db = await getDB()
    await this.db?.run(SQLS.createIndexes)
  }

  get connected() {
    return !!this.db
  }

  dispose() {
    this.rustServer?.stopPoller()
    this.rustServer?.destroy()
    return this.db?.dispose()
  }

  getAccountLogins(): Promise<string[]> {
    return this.db!.pluck_all(SQLS.getAccountLogins)
  }

  private calledRustServerSetOnce = false

  async updateRustServer(maxRowID: number, maxDateRead: number) {
    if (this.calledRustServerSetOnce) return
    this.calledRustServerSetOnce = true
    while (!this.rustServer) {
      await bluebird.delay(10)
    }
    this.rustServer.startPoller(maxRowID, maxDateRead)
  }

  setLastCursor(allMsgRows: MappedMessageRow[]) {
    if (!allMsgRows.length) return
    const maxDateRead = maxBy(allMsgRows, 'date_read')?.date_read
    const maxRowID = maxBy(allMsgRows, 'msgRowID')?.msgRowID
    if (maxRowID > this.lastRowID) {
      this.lastRowID = maxRowID
    }
    if (maxDateRead > this.lastDateRead) {
      this.lastDateRead = maxDateRead
    }
    this.updateRustServer(maxRowID, maxDateRead)
  }

  startPolling(onEvent: OnServerEventCallback) {
    this.rustServer = new RustServer(onEvent)
    // let wokeFromSleep = false
    // parentPort!.on('message', value => {
    //   if (typeof value === 'string' && value === 'powermonitor-on-resume') {
    //     wokeFromSleep = true
    //   }
    // })
  }

  getThreadParticipants(chatRowID: number): Promise<MappedHandleRow[]> {
    return this.db.all(SQLS.getThreadParticipants, [chatRowID])
  }

  getThreadParticipantsWithWait(chatRow: ChatRow, userIDs: string[]) {
    return waitForRows(() => this.getThreadParticipants(chatRow.ROWID), userIDs.length + 1)
  }

  async fetchLastMessageRows(chatRowID: number): Promise<[MappedMessageRow[], MappedAttachmentRow[], MappedReactionMessageRow[]]> {
    const msgRows: MappedMessageRow[] = await this.db.all(SQLS.getMessagesWithChatRowID(undefined, 5), [chatRowID])
    msgRows.reverse()
    const msgRowIDs = msgRows.map(m => m.msgRowID)
    const msgGUIDs = msgRows.map(m => m.msgID)
    const [attachmentRows, reactionRows] = msgRows.length === 0 ? [] : await Promise.all([
      this.getAttachments(msgRowIDs),
      this.getMessageReactions(msgGUIDs, undefined, chatRowID),
    ])
    return [msgRows, attachmentRows, reactionRows]
  }

  async getThread(chatGUID: string): Promise<MappedChatRow> {
    const chat: MappedChatRow = await this.db.get(SQLS.getThread, [chatGUID])
    if (chat) this.chatGUIDRowIDMap.set(chat.guid, chat.ROWID)
    return chat
  }

  getThreadWithWait(chatGUID: string) {
    return waitForRows(() => this.getThread(chatGUID).then(c => [c]), 1)
  }

  async getThreads(cursor: string, direction: 'after' | 'before'): Promise<MappedChatRow[]> {
    const chats: MappedChatRow[] = await this.db.all(SQLS.getThreads(MAP_DIRECTION_TO_SQL_OP[direction]), cursor ? [+cursor] : [])
    chats.forEach(chat => {
      this.chatGUIDRowIDMap.set(chat.guid, chat.ROWID)
    })
    return chats
  }

  getGroupImages(): Promise<[string, string][]> {
    return this.db.raw_all(SQLS.getGroupImages)
  }

  // getMessagesWithChatRowID(chatGUID: string, cursor: string, direction: 'after' | 'before'): Promise<MappedMessageRow[]> {
  //   const cursorDirection = cursor && MAP_DIRECTION_TO_SQL_OP[direction]
  //   const chatRowID = this.chatGUIDRowIDMap.get(chatGUID)
  //   return this.db.all(
  //     SQLS.getMessagesWithChatRowID(cursorDirection),
  //     cursor ? [chatRowID, +cursor] : [chatRowID],
  //   )
  // }

  getMessages(chatGUID: string, cursor: string, direction: 'after' | 'before'): Promise<MappedMessageRow[]> {
    const cursorDirection = cursor && MAP_DIRECTION_TO_SQL_OP[direction]
    return this.db.all(
      SQLS.getMessages(cursorDirection),
      cursor ? [chatGUID, +cursor] : [chatGUID],
    )
  }

  private imageSizeMemoized = memoize(imageSizeAsync)

  getAttachments(msgRowIDs: number[]): Promise<MappedAttachmentRow[]> {
    const attachments: Promise<MappedAttachmentRow[]> = this.db.all(SQLS.getAttachments(msgRowIDs), msgRowIDs)
    return bluebird.map(attachments, async a => {
      const filePath = replaceTilde(a.filename)
      const { base, ext: _ext } = filePath ? path.parse(filePath) : { base: a.transfer_name, ext: '' }
      const ext = _ext.slice(1).toLowerCase()
      const fileName = a.transfer_name || base
      Object.assign(a, { ext, fileName, filePath })
      if ((IMAGE_EXTS.includes(ext) || ext === 'pluginpayloadattachment') && ext !== 'heic') { // heic isn't supported yet
        try {
          const { width, height } = await this.imageSizeMemoized(filePath)
          a.size = { width, height }
        } catch (err) { texts.error(err) }
      }
      return a
    })
  }

  getMessageReactions(msgGUIDs: string[], chatGUID: string, chatRowID: number = this.chatGUIDRowIDMap.get(chatGUID)): Promise<MappedReactionMessageRow[]> {
    return this.db.all(SQLS.getMessageReactions(msgGUIDs), [...msgGUIDs, chatRowID])
  }

  async searchMessages(typed: string, chatGUID: string, cursor: string, direction: string) {
    // @ts-expect-error replaceAll
    const typedEscaped = `%${typed.replaceAll('%', '\\%')}%`
    const cursorDirection = cursor && MAP_DIRECTION_TO_SQL_OP[direction]
    const bindings = cursor ? [typedEscaped, +cursor] : [typedEscaped]
    if (chatGUID) bindings.push(chatGUID)
    const msgRows: MappedMessageRow[] = await this.db.all(
      SQLS.searchMessages(cursorDirection, chatGUID),
      bindings,
    )
    msgRows.reverse()
    return msgRows
  }

  getThreadMessagesCount(chatGUID: string): Promise<number> {
    return this.db.pluck_get(SQLS.getMsgCount, chatGUID)
  }

  private getMappedMessagesWithoutExtraRows = async (chatGUID: string, cursor: string, direction: 'before' | 'after') => {
    const msgRows = await this.getMessages(chatGUID, cursor, direction)
    if (direction !== 'after') msgRows.reverse()
    const items = mapMessages(msgRows, [], [], this.papi.currentUserID)
    return {
      items,
      hasMore: msgRows.length === MESSAGES_LIMIT,
    }
  }

  // todo handle emoji only messages
  private canReactToMessage = (m: Message): boolean => m.text && !m.links?.length && !m.tweets?.length

  private findClosestTextInDirection = async (direction: 'before' | 'after', threadID: string, messageGUID: string, mapped: Message): Promise<{ offset: number, guid: string }> => {
    texts.log('searching for neighboring message', direction, threadID, messageGUID, mapped.cursor)
    const messages = await this.getMappedMessagesWithoutExtraRows(threadID, mapped.cursor, direction as 'before' | 'after') // todo handle message splitting, optimize
    // texts.log(direction, messages.items.map((m, mIndex) => [m.timestamp, direction === 'before' ? -(messages.items.length - mIndex) : mIndex + 1]))
    const find = direction === 'before' ? findLastIndex : findIndex
    const mIndex = find(messages.items.filter(m => !m.isHidden), this.canReactToMessage)
    if (mIndex > -1) {
      const m = messages.items[mIndex]
      return { guid: m.id, offset: direction === 'before' ? -(messages.items.length - mIndex) : mIndex + 1 }
    }
  }

  findClosestTextMessage = async (threadID: string, messageGUID: string): Promise<{ offset: number, guid: string }> => {
    const message = await this.db.get('SELECT m.ROWID AS msgRowID, m.guid AS msgID, m.* FROM message AS m WHERE guid = ?', [messageGUID])
    if (!message) throw Error('message not found')
    const [mapped] = mapMessage(message, [], [], this.papi.currentUserID) // todo optimize mapping not needed
    if (this.canReactToMessage(mapped)) return { guid: mapped.id, offset: 0 }
    // todo loop over more pages if not found
    const [before, after] = await Promise.all([
      this.findClosestTextInDirection('before', threadID, messageGUID, mapped),
      this.findClosestTextInDirection('after', threadID, messageGUID, mapped),
    ])
    if (before && after) {
      return after.offset < -before.offset ? after : before
    } // else
    if (before) {
      return before
    } // else
    if (after) {
      return after
    } // else
    throw new Error('closest text message not found')
  }

  // async markMessageRead(messageID: string) {
  //   await this.db.run(SQLS.updateReadTimestamp, [messageID])
  // }
}
