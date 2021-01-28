import { promises as fs } from 'fs'
import os from 'os'
import path from 'path'
import bluebird from 'bluebird'
import { v4 as uuid } from 'uuid'
import { PlatformAPI, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, InboxName, ReAuthError, MessageContent, PaginationArg, ActivityType, User, AccountInfo } from '@textshq/platform-sdk'

import { convertCGBI } from './async-cgbi-to-png'
import { mapThreads, mapMessages, mapThread, mapAccountLogin } from './mappers'
import iMessageAPI from './as2'
import ThreadReadStore from './thread-read-store'
// import { trackTime } from '../../common/analytics'
import { IS_BIG_SUR_OR_UP } from './constants'
import DatabaseAPI, { THREADS_LIMIT, MESSAGES_LIMIT } from './db-api'

export default class AppleiMessage implements PlatformAPI {
  private currentUserID: string

  private threadReadStore: ThreadReadStore

  private dbAPI = new DatabaseAPI()

  private ensureDB = () => {
    if (!this.dbAPI.connected) throw new ReAuthError('Unable to connect to iMessage database')
  }

  private api = iMessageAPI()

  getCurrentUser = async (): Promise<CurrentUser> => {
    this.ensureDB()
    const logins = await this.dbAPI.getAccountLogins()
    const accounts = logins.map(mapAccountLogin).filter(Boolean)
    this.currentUserID = accounts[0] || 'default'
    return {
      id: this.currentUserID,
      displayText: accounts.join(', '),
    }
  }

  login = async (): Promise<LoginResult> => {
    await this.dbAPI.init()
    if (this.dbAPI.connected) return { type: 'success' }
    return { type: 'error', errorMessage: 'Please grant full disk access and try again.' }
  }

  init = async (_: any, { dataDirPath }: AccountInfo) => {
    await this.dbAPI.init()
    this.threadReadStore = new ThreadReadStore(path.dirname(dataDirPath))
  }

  dispose = () => {
    this.api.exit()
    return this.dbAPI.dispose()
  }

  subscribeToEvents = (onEvent: OnServerEventCallback): void => {
    this.dbAPI.startPolling(onEvent)
  }

  searchUsers = (typed: string): User[] => []

  createThread = async (userIDs: string[]) => {
    if (userIDs.length === 0) return null
    this.ensureDB()
    const threadID = await this.api.createThread(userIDs)
    await bluebird.delay(10)
    const [chatRow] = await this.dbAPI.getThreadWithWait(threadID)
    if (!chatRow) return
    const handleRows = await this.dbAPI.getThreadParticipantsWithWait(chatRow, userIDs)
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

  getThreads = async (inboxName: InboxName, { cursor, direction }: PaginationArg = { cursor: null, direction: null }): Promise<Paginated<Thread>> => {
    if (inboxName !== InboxName.NORMAL) {
      return {
        items: [],
        hasMore: false,
        oldestCursor: null,
      }
    }
    this.ensureDB()
    const chatRows = await this.dbAPI.getThreads(cursor, direction)
    const mapMessageArgsMap: { [threadID: string]: [any[], any[]] } = {}
    const handleRowsMap: { [threadID: string]: any[] } = {}
    const allMsgRows = []
    const [,, groupImagesRows] = await Promise.all([
      bluebird.map(chatRows, async chatRow => {
        const [msgRows, attachmentRows] = await this.dbAPI.fetchLastMessageRow(chatRow.ROWID)
        allMsgRows.push(...msgRows)
        mapMessageArgsMap[chatRow.guid] = [msgRows, attachmentRows]
      }),
      bluebird.map(chatRows, async chatRow => {
        handleRowsMap[chatRow.guid] = await this.dbAPI.getThreadParticipants(chatRow.ROWID)
      }),
      IS_BIG_SUR_OR_UP ? this.dbAPI.getGroupImages() : [],
    ])
    const groupImagesMap: { [attachmentID: string]: string } = {};
    (groupImagesRows as [string, string][])?.forEach(([attachmentID, fileName]) => {
      groupImagesMap[attachmentID] = fileName
    })
    const items = mapThreads(chatRows, { mapMessageArgsMap, handleRowsMap, groupImagesMap, currentUserID: this.currentUserID, threadReadStore: this.threadReadStore })
    if (!cursor) this.dbAPI.setLastCursor(allMsgRows)
    return {
      items,
      hasMore: chatRows.length === THREADS_LIMIT,
      oldestCursor: chatRows[chatRows.length - 1]?.msgDate?.toString(),
    }
  }

  getMessages = async (threadID: string, { cursor, direction }: PaginationArg = { cursor: null, direction: null }): Promise<Paginated<Message>> => {
    this.ensureDB()
    const msgRows = await this.dbAPI.getMessages(threadID, cursor, direction)
    msgRows.reverse()
    const msgRowIDs = msgRows.map(m => m.msgRowID)
    const attachmentRows = msgRows.length ? await this.dbAPI.getAttachments(msgRowIDs) : []
    const items = mapMessages(msgRows, attachmentRows, this.currentUserID)
    return {
      items,
      hasMore: msgRows.length === MESSAGES_LIMIT,
    }
  }

  searchMessages = async (typed: string, { cursor, direction }: PaginationArg = { cursor: null, direction: null }, threadID?: string): Promise<Paginated<Message>> => {
    this.ensureDB()
    const msgRows = await this.dbAPI.searchMessages(typed, threadID, cursor, direction)
    const msgRowIDs = msgRows.map(m => m.msgRowID)
    const attachmentRows = msgRows.length ? await this.dbAPI.getAttachments(msgRowIDs) : []
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
    const count = await this.dbAPI.getThreadMessagesCount(threadID)
    await this.api.sendTextMessage(threadID, text)
    let newCount: number = 0
    while (newCount === 0) {
      await bluebird.delay(25)
      newCount = await this.dbAPI.getThreadMessagesCount(threadID) - count
    }
    return true
  }

  private sendFileFromFilePath = async (threadID: string, filePath: string) => {
    const count = await this.dbAPI.getThreadMessagesCount(threadID)
    await this.api.sendFile(threadID, filePath)
    let newCount: number = 0
    while (newCount === 0) {
      await bluebird.delay(25)
      newCount = await this.dbAPI.getThreadMessagesCount(threadID) - count
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
    // await this.dbAPI.db.run(SQLS.updateReadTimestamp, [messageCursor, threadID])
  }

  //   private getThreadMessagesChecksum = async (threadID: string, afterCursor: string) => {
  //     const x = await this.dbAPI.db.get(`SELECT count(*) as c
  // FROM message as m
  // ${COMMON_JOINS}
  // WHERE t.guid = ?
  // AND m.date >= ?
  // ORDER BY date DESC`, [threadID, afterCursor])
  //     return x.c
  //   }

  getAsset = async (pathHex: string) => {
    const filePath = Buffer.from(pathHex, 'hex').toString()
    const buffer = await fs.readFile(filePath)
    return convertCGBI(buffer)
  }
}
