import { OnServerEventCallback, texts, IAsyncSqlite } from '@textshq/platform-sdk'
import { setTimeout as setTimeoutAsync } from 'node:timers/promises'

import { CHAT_DB_PATH } from './constants'
import type { ChatRow } from './types'
import swiftServer from './SwiftServer/lib'

const SQLS = {
  getThread: 'SELECT * FROM chat WHERE guid = ?',
  getMaxDateRead: 'SELECT MAX(date_read) FROM message',
}

declare const AsyncSqlite: IAsyncSqlite

async function getDB() {
  const instance = new AsyncSqlite()
  await instance.init(CHAT_DB_PATH)
  return instance
}

export default class DatabaseAPI {
  // HACK: this is populated by the `PlatformAPI` subclass, because we need to
  // hand it off to the poller (SwiftServer) in order for it to trigger updates
  eventSender: OnServerEventCallback | null = null

  constructor(private db: IAsyncSqlite) {}

  static async make() {
    texts.log('imsg: creating DatabaseAPI')
    const db = await getDB()
    texts.log('imsg: returning new DatabaseAPI')
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
    return this.db.get<string[], ChatRow>(SQLS.getThread, chatGUID)
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
