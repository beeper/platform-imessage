import path from 'path'
import { memoize } from 'lodash'
import { OnServerEventCallback, texts, IAsyncSqlite } from '@textshq/platform-sdk'
import { setTimeout as setTimeoutAsync } from 'node:timers/promises'

import { CHAT_DB_PATH, IS_VENTURA_OR_UP } from './constants'
import { replaceTilde } from './util'
import IMAGE_EXTS from './image-exts.json'
import type { ChatRow, MappedAttachmentRow } from './types'
import swiftServer from './SwiftServer/lib'

const SQLS = {
  getThread: 'SELECT * FROM chat WHERE guid = ?',
  getChatImageByGUID: 'SELECT filename FROM attachment WHERE guid = ?',

  createIndexes: IS_VENTURA_OR_UP
    ? 'CREATE INDEX IF NOT EXISTS message_idx_date_read ON message (date_read); CREATE INDEX IF NOT EXISTS message_idx_date_edited ON message (date_edited)'
    : 'CREATE INDEX IF NOT EXISTS message_idx_date_read ON message (date_read)',
  // updateReadTimestamp: 'UPDATE message SET is_read = TRUE WHERE guid = ?',

  getAttachments: (msgIDs: number[]) => `SELECT m.ROWID AS msgRowID, a.filename, a.transfer_name, a.total_bytes, a.is_sticker, a.guid AS attachmentID, a.transfer_state
FROM message AS m
LEFT JOIN message_attachment_join AS maj ON maj.message_id = m.ROWID
LEFT JOIN attachment AS a ON a.ROWID = maj.attachment_id
WHERE m.ROWID IN (${new Array(msgIDs.length).fill('?').join(', ')})`,
  threadUnreadCount: `SELECT COUNT(m.ROWID)
FROM message AS m
INNER JOIN chat_message_join AS cmj ON m.ROWID = cmj.message_id
WHERE cmj.chat_id = ?
AND m.item_type == 0
AND m.is_read == 0
AND m.is_from_me == 0`,
  getMaxDateRead: 'SELECT MAX(date_read) FROM message',
}

declare const AsyncSqlite: IAsyncSqlite

async function getDB() {
  const instance = new AsyncSqlite()
  await instance.init(CHAT_DB_PATH)
  return instance
}

export default class DatabaseAPI {
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

  async getThread(chatGUID: string): Promise<ChatRow | undefined> {
    const chat = await this.db.get<string[], ChatRow>(SQLS.getThread, chatGUID)
    if (chat) this.chatGUIDRowIDMap.set(chat.guid, chat.ROWID)
    return chat
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

  async getChatImageByGUID(attachmentGUID: string): Promise<string | undefined> {
    const fileName = await this.db.pluck_get<string[], string>(SQLS.getChatImageByGUID, attachmentGUID)
    return fileName ? replaceTilde(fileName) : undefined
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
