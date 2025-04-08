import path from 'path'
import { promisify } from 'util'
import { maxBy, memoize, findIndex, findLastIndex } from 'lodash'
import imageSizeCallback from 'image-size'
import { Message, OnServerEventCallback, texts, IAsyncSqlite, PaginationArg } from '@textshq/platform-sdk'
import { setTimeout as setTimeoutAsync } from 'timers/promises'

import { CHAT_DB_PATH, IS_SEQUOIA_OR_UP, IS_VENTURA_OR_UP } from './constants'
import { Server as RustServer, IServer as IRustServer } from './RustServer/lib'
import { replaceTilde } from './util'
import { mapMessages, MessageWithExtra } from './mappers'
import IMAGE_EXTS from './image-exts.json'
import { isSelectable } from './common-util'
import type { ChatRow, MappedAttachmentRow, MappedChatRow, MappedMessageRow, MappedHandleRow, MappedReactionMessageRow, AXMessageSelection } from './types'
import type PAPI from './api'

const imageSizeAsync = promisify(imageSizeCallback)

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
WHERE m.ROWID IN (${new Array(msgIDs.length).fill('?').join(', ')})`,
  getMessageReactions: (msgGUIDs: string[]) => `SELECT is_from_me, handle_id, associated_message_type, associated_message_guid, ${IS_SEQUOIA_OR_UP ? 'associated_message_emoji,' : ''} h.id AS participantID
FROM message AS m
LEFT JOIN handle AS h ON m.handle_id = h.ROWID
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
WHERE REPLACE(SUBSTR(associated_message_guid, INSTR(associated_message_guid, '/') + 1), 'bp:', '') IN (${msgGUIDs.map(() => '?').join(',')})
AND chat_id = ?`,
  getMessagesWithChatRowID: (cursorDirection?: '<' | '>', limit = MESSAGES_LIMIT) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${MESSAGE_JOINS}
WHERE cmj.chat_id = ?
${cursorDirection ? `AND m.date ${cursorDirection} ?` : ''}
ORDER BY date ${cursorDirection === '>' ? 'ASC' : 'DESC'}
LIMIT ${limit}`,
  getMessages: (cursorDirection?: string, limit = MESSAGES_LIMIT) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${MESSAGE_JOINS}
WHERE t.guid = ?
${cursorDirection ? `AND m.date ${cursorDirection} ?` : ''}
ORDER BY date ${cursorDirection === '>' ? 'ASC' : 'DESC'}
LIMIT ${limit}`,
  getMessage: `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${MESSAGE_JOINS}
WHERE m.guid = ?`,
  threadUnreadCount: `SELECT COUNT(m.ROWID)
FROM message AS m
INDEXED BY message_idx_isRead_isFromMe_itemType
INNER JOIN chat_message_join AS cmj ON m.ROWID = cmj.message_id
WHERE cmj.chat_id = ?
AND m.item_type == 0
AND m.is_read == 0
AND m.is_from_me == 0`,
  searchMessages: (cursorDirection?: string, chatGUID?: string, mediaOnly?: boolean, fromMe?: boolean) => `SELECT
${MAP_MESSAGES_COLS}
FROM message AS m
${MESSAGE_JOINS}
WHERE m.text LIKE ? ESCAPE '\\' COLLATE NOCASE
${cursorDirection ? `AND m.date ${cursorDirection} ?` : ''}
${chatGUID ? 'AND t.guid = ?' : ''}
${mediaOnly ? 'AND cache_has_attachments = 1' : ''}
${fromMe ? 'AND is_from_me = 1' : ''}
ORDER BY date ${cursorDirection === '>' ? 'ASC' : 'DESC'}
LIMIT ${MESSAGES_LIMIT}`,
  isMessageRead: 'SELECT is_read FROM message WHERE guid = ?',
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

  private rustServer: IRustServer | null = null

  constructor(private db: IAsyncSqlite, private readonly papi: InstanceType<typeof PAPI>) {}

  static async make(papi: InstanceType<typeof PAPI>) {
    texts.log('imsg: creating DatabaseAPI')
    const db = await getDB()
    texts.log('imsg: creating indexes')
    await db.run(SQLS.createIndexes)
    return new DatabaseAPI(db, papi)
  }

  dispose() {
    this.rustServer?.stopPoller()
    this.rustServer = null

    return this.db.dispose()
  }

  // this should ideally be fetched from rust server
  async getUnreadCounts(): Promise<Map<number /* chat rowid */, number>> {
    const rows = await this.db.all<[], { unread_count: number, chat_id: number }>(SQLS.getUnreadCounts)
    return new Map(rows.map(row => [row.chat_id, row.unread_count]))
  }

  getAccountLogins = (): Promise<string[]> =>
    this.db.pluck_all<void[], string>(SQLS.getAccountLogins)

  private calledRustServerSetOnce = false

  async updateRustServer(maxRowID: number, maxDateRead: number) {
    if (this.calledRustServerSetOnce) return
    this.calledRustServerSetOnce = true
    while (!this.rustServer) {
      await setTimeoutAsync(10)
    }
    this.rustServer!.startPoller(BigInt(maxRowID), BigInt(maxDateRead))
  }

  setLastCursor(allMsgRows: MappedMessageRow[]) {
    if (!allMsgRows.length) return
    const maxDateRead = maxBy(allMsgRows, 'date_read')!.date_read
    const maxRowID = maxBy(allMsgRows, 'ROWID')!.ROWID
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

  async isThreadRead(chatGUID: string): Promise<boolean> {
    const rowID = this.chatGUIDRowIDMap.get(chatGUID)
    if (typeof rowID !== 'number') return false
    return (await this.db.pluck_get<number[], number>(SQLS.threadUnreadCount, rowID)) === 0
  }

  getThreadWithWait = (chatGUID: string) =>
    waitForRows(() => this.getThread(chatGUID).then(c => [c]), 1)

  async getThreads(pagination?: PaginationArg): Promise<MappedChatRow[]> {
    // FIXME: this shouldn't be parsing to a number due to precision loss
    const chats = await this.db.all<number[], MappedChatRow>(SQLS.getThreads(pagination ? MAP_DIRECTION_TO_SQL_OP[pagination.direction] : undefined), ...(pagination ? [Number.parseInt(pagination.cursor, 10)] : []))
    chats.forEach(chat => {
      this.chatGUIDRowIDMap.set(chat.guid, chat.ROWID)
    })
    return chats
  }

  getGroupImages = (): Promise<[string, string][]> =>
    this.db.raw_all<void[], [string, string]>(SQLS.getGroupImages)

  // getMessagesWithChatRowID(chatGUID: string, cursor: string, direction: 'after' | 'before'): Promise<MappedMessageRow[]> {
  //   const cursorDirection = cursor && MAP_DIRECTION_TO_SQL_OP[direction]
  //   const chatRowID = this.chatGUIDRowIDMap.get(chatGUID)
  //   return this.db.all(
  //     SQLS.getMessagesWithChatRowID(cursorDirection),
  //     cursor ? [chatRowID, +cursor] : [chatRowID],
  //   )
  // }

  getMessages(chatGUID: string, pagination?: PaginationArg): Promise<MappedMessageRow[]> {
    // FIXME: this shouldn't be parsing to a number due to precision loss
    const bindings = pagination ? [chatGUID, Number.parseInt(pagination.cursor, 10)] : [chatGUID]
    return this.db.all<typeof bindings, MappedMessageRow>(SQLS.getMessages(pagination?.direction), ...bindings)
  }

  getMessage = (messageGUID: string): Promise<MappedMessageRow> =>
    this.db.get<string[], MappedMessageRow>(SQLS.getMessage, messageGUID)

  private imageSizeMemoized = memoize(imageSizeAsync)

  async getAttachments(msgRowIDs: number[]): Promise<MappedAttachmentRow[]> {
    const attachments = await this.db.all<number[], MappedAttachmentRow>(SQLS.getAttachments(msgRowIDs), ...msgRowIDs)
    return Promise.all(attachments.map(async a => {
      const filePath = replaceTilde(a.filename)
      const { base, ext: _ext } = filePath ? path.parse(filePath) : { base: a.transfer_name, ext: '' }
      const ext = _ext.slice(1).toLowerCase()
      const fileName = a.transfer_name || base
      Object.assign(a, { ext, fileName, filePath })
      if ((IMAGE_EXTS.includes(ext) || ext === 'pluginpayloadattachment') && ext !== 'heic') { // heic isn't supported yet
        try {
          const imageSize = await this.imageSizeMemoized(filePath)
          if (!imageSize) {
            texts.error("couldn't determine image size")
            return a
          }
          const { width, height, orientation } = imageSize
          if (!width || !height) {
            texts.error('image size had bogus dimensions')
            return a
          }
          /*
            orientation:
            https://exiftool.org/TagNames/EXIF.html#:~:text=0x0112,8%20=%20Rotate%20270%20CW
            1 = Horizontal (normal)
            2 = Mirror horizontal
            3 = Rotate 180
            4 = Mirror vertical
            5 = Mirror horizontal and rotate 270 CW
            6 = Rotate 90 CW
            7 = Mirror horizontal and rotate 90 CW
            8 = Rotate 270 CW
          */
          a.size = orientation && [5, 6, 7, 8].includes(orientation) ? { width: height, height: width } : { width, height }
        } catch (err) { texts.error(err) }
      }
      return a
    }))
  }

  getMessageReactions(msgGUIDs: string[], chat: ChatRef): Promise<MappedReactionMessageRow[]> {
    let chatRowID: number
    if (chat.type === 'guid') {
      const rowID = this.chatGUIDRowIDMap.get(chat.guid)
      if (!rowID) throw new Error('while getting reactions: expected GUID to be in cache')
      chatRowID = rowID
    } else {
      chatRowID = chat.rowid
    }

    const bindings = [...msgGUIDs, chatRowID]
    return this.db.all<typeof bindings, MappedReactionMessageRow>(SQLS.getMessageReactions(msgGUIDs), ...bindings)
  }

  async searchMessages(typed: string, chatGUID?: string, mediaOnly?: boolean, pagination?: PaginationArg, sender?: string): Promise<MappedMessageRow[]> {
    const typedEscaped = `%${typed.replaceAll('%', '\\%')}%`
    // FIXME: this shouldn't be parsing to a number due to precision loss
    const bindings = pagination ? [typedEscaped, Number.parseInt(pagination.cursor, 10)] : [typedEscaped]
    if (chatGUID) bindings.push(chatGUID)
    const msgRows = await this.db.all<typeof bindings, MappedMessageRow>(
      SQLS.searchMessages(pagination ? MAP_DIRECTION_TO_SQL_OP[pagination.direction] : undefined, chatGUID, mediaOnly, sender === 'me'),
      ...bindings,
    )
    msgRows.reverse()
    return msgRows
  }

  getThreadMessagesCount = (chatGUID: string): Promise<number> =>
    this.db.pluck_get<string[], number>(SQLS.getMsgCount, chatGUID)

  getLastMessageRowID = (): Promise<number> =>
    this.db.pluck_get("select seq from sqlite_sequence where name = 'message'")

  getSentMessageIDsSince = (rowID: number): Promise<[number, string][]> =>
    this.db.raw_all<number[], [number, string]>('select ROWID, guid from message where is_from_me = 1 and ROWID > ?', rowID)

  getThreadIDForMessageRowID = (rowID: number): Promise<string> =>
    this.db.pluck_get(`SELECT t.guid
FROM message AS m
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
WHERE m.ROWID = ?`, rowID)

  private getMappedMessagesWithoutExtraRows = async (chatGUID: string, pagination?: PaginationArg) => {
    const msgRows = await this.getMessages(chatGUID, pagination)
    if (pagination?.direction !== 'after') msgRows.reverse()
    const items = mapMessages(msgRows, [], [], this.papi.currentUser!.id)
    return {
      items,
      hasMore: msgRows.length === MESSAGES_LIMIT,
    }
  }

  private findClosestTextInDirection = async (direction: 'before' | 'after', threadID: string, mapped: Message, msgRow: MappedMessageRow): Promise<AXMessageSelection | undefined> => {
    texts.log('[imessage] searching for neighboring message', direction, threadID, mapped.id, mapped.cursor)
    if (!mapped.cursor) throw new Error('while trying to find closest text: message has no cursor')
    const messages = await this.getMappedMessagesWithoutExtraRows(threadID, { cursor: mapped.cursor, direction }) // todo handle message splitting, optimize
    const unhiddenMessages = messages.items.filter(m => !m.isHidden)
    // texts.log(direction, messages.items.map((m, mIndex) => [m.timestamp, direction === 'before' ? -(messages.items.length - mIndex) : mIndex + 1]))
    const find = direction === 'before' ? findLastIndex : findIndex
    const mIndex = find(unhiddenMessages as MessageWithExtra[], isSelectable)
    if (mIndex > -1) {
      const m = unhiddenMessages[mIndex]
      return { messageGUID: m.id, offset: direction === 'before' ? -(unhiddenMessages.length - mIndex) : mIndex + 1, cellID: msgRow.balloon_bundle_id, cellRole: null }
    }
  }

  findClosestTextMessage = async (threadID: string, messageGUIDWithPart: string, mapped: MessageWithExtra, msgRow: MappedMessageRow): Promise<AXMessageSelection> => {
    const [messageGUID, partString] = messageGUIDWithPart.split('_', 2)
    const part = +partString || 0
    texts.log('[imessage] findClosestTextMessage', messageGUID, part)
    // const message = await this.db.get('SELECT m.ROWID, m.guid AS msgID, m.* FROM message AS m WHERE guid = ?', messageGUID)
    // if (!message) throw Error('message not found')
    // const [mapped] = mapMessage(message, [], [], this.papi.currentUser.id) // todo optimize mapping not needed
    if (isSelectable(mapped)) return { messageGUID: mapped.id, offset: 0, cellID: msgRow.balloon_bundle_id, cellRole: null }
    // todo loop over more pages if not found
    const [before, after] = await Promise.all([
      this.findClosestTextInDirection('before', threadID, mapped, msgRow),
      this.findClosestTextInDirection('after', threadID, mapped, msgRow),
    ])
    if (before) before.offset -= part
    if (after) after.offset += part
    if (before && after) return after.offset < -before.offset ? after : before
    if (before) return before
    if (after) return after
    throw new Error('closest text message not found')
  }

  isMessageRead = (messageGUID: string): Promise<number> =>
    this.db.pluck_get<string[], number>(SQLS.isMessageRead, messageGUID)

  isNotEmpty = async (): Promise<boolean> =>
    (await this.db.pluck_get<void[], number>('SELECT (SELECT count(*) FROM message) > 0')) === 1

  // async markMessageRead(messageID: string) {
  //   await this.db.run(SQLS.updateReadTimestamp, messageID)
  // }
}
