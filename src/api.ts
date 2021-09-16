import { existsSync, promises as fs } from 'fs'
import os from 'os'
import path from 'path'
import childProcess from 'child_process'
import bluebird from 'bluebird'
import { v4 as uuid } from 'uuid'
import { PlatformAPI, ServerEventType, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, InboxName, ReAuthError, MessageContent, PaginationArg, ActivityType, User, AccountInfo, texts, ServerEvent } from '@textshq/platform-sdk'

import { convertCGBI } from './async-cgbi-to-png'
import { mapThreads, mapMessages, mapThread, mapAccountLogin } from './mappers'
import iMessageAPI from './as2'
import ThreadReadStore from './thread-read-store'
// import { trackTime } from '../../common/analytics'
import { IS_BIG_SUR_OR_UP } from './constants'
import DatabaseAPI, { THREADS_LIMIT, MESSAGES_LIMIT } from './db-api'
import { csrStatus } from './csr'
import _swiftServer, { ActivityStatus } from './SwiftServer/lib'
import type { MappedAttachmentRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow } from './types'

export default class AppleiMessage implements PlatformAPI {
  private currentUserID: string

  private threadReadStore: ThreadReadStore

  private dbAPI = new DatabaseAPI()

  private ensureDB = () => {
    if (!this.dbAPI.connected) throw new ReAuthError('Unable to connect to iMessage database')
  }

  private api = iMessageAPI()

  private swiftServer: Promise<typeof _swiftServer>

  private onEvent: OnServerEventCallback

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

  private enableMarkAsRead: boolean

  private initSwiftServer = async () => {
    if (!IS_BIG_SUR_OR_UP) return null
    try {
      await _swiftServer.init()
      return _swiftServer
    } catch (err) {
      texts.Sentry.captureException(err, { tags: { platform: 'imessage' } })
      texts.error('[imessage] SwiftServer error', err)
      return null
    }
  }

  init = async (_: undefined, { dataDirPath }: AccountInfo) => {
    this.enableMarkAsRead = !existsSync(path.join(dataDirPath, 'disable-imessage-mark-as-read')) && IS_BIG_SUR_OR_UP
    await this.dbAPI.init()
    if (this.dbAPI.connected) { // we have FDA which means user went through auth flow
      this.swiftServer = this.initSwiftServer()
    }
    this.threadReadStore = new ThreadReadStore(path.dirname(dataDirPath))
    csrStatus().then(status => {
      texts.trackPlatformEvent({
        csrutilStatus: status,
        enabled: status.includes('enabled.'),
      })
    }).catch(console.error)
  }

  dispose = () => {
    this.swiftServer.then(s => s?.dispose())
    this.api.dispose()
    return this.dbAPI.dispose()
  }

  subscribeToEvents = (onEvent: OnServerEventCallback): void => {
    this.dbAPI.startPolling(onEvent)
    this.onEvent = (events: ServerEvent[]) => {
      const evs: ServerEvent[] = []
      events.forEach(ev => {
        if (ev.type === ServerEventType.TOAST) {
          texts.Sentry.captureMessage(`iMessage RustServer: ${ev.toast.text}`)
        } else {
          evs.push(ev)
        }
      })
      onEvent(evs)
    }
  }

  searchUsers = (typed: string): User[] => []

  getThread = async (threadID: string) => {
    const chatRow = await this.dbAPI.getThread(threadID)
    if (!chatRow) return
    const handleRows = await this.dbAPI.getThreadParticipants(chatRow.ROWID)
    return mapThread(
      chatRow,
      {
        handleRowsMap: { [chatRow.guid]: handleRows },
        currentUserID: this.currentUserID,
        threadReadStore: this.threadReadStore,
      },
    )
  }

  private catalinaCreateThread = async (userIDs: string[]) => {
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

  createThread = async (userIDs: string[]) => {
    if (userIDs.length === 0) return null
    this.ensureDB()
    if (!IS_BIG_SUR_OR_UP) return this.catalinaCreateThread(userIDs)
    if (userIDs.length === 1) {
      const address = userIDs[0]
      const existingThread = await this.getThread(`iMessage;-;${address}`)
      if (existingThread) return existingThread;
      (await this.swiftServer).createThread([address])
    } else {
      // potential todo: we can search for an existing thread with the specified userIDs here
      (await this.swiftServer).createThread(userIDs)
    }
  }

  getThreads = async (inboxName: InboxName, pagination: PaginationArg): Promise<Paginated<Thread>> => {
    if (inboxName !== InboxName.NORMAL) {
      return {
        items: [],
        hasMore: false,
        oldestCursor: null,
      }
    }
    const { cursor, direction } = pagination || { cursor: null, direction: null }
    this.ensureDB()
    const chatRows = await this.dbAPI.getThreads(cursor, direction)
    const mapMessageArgsMap: { [chatGUID: string]: [MappedMessageRow[], MappedAttachmentRow[], MappedReactionMessageRow[]] } = {}
    const handleRowsMap: { [chatGUID: string]: MappedHandleRow[] } = {}
    const allMsgRows: MappedMessageRow[] = []
    const [,, groupImagesRows] = await Promise.all([
      bluebird.map(chatRows, async chat => {
        const [msgRows, attachmentRows, reactionRows] = await this.dbAPI.fetchLastMessageRows(chat.ROWID)
        if (!cursor) allMsgRows.push(...msgRows)
        mapMessageArgsMap[chat.guid] = [msgRows, attachmentRows, reactionRows]
      }),
      bluebird.map(chatRows, async chat => {
        handleRowsMap[chat.guid] = await this.dbAPI.getThreadParticipants(chat.ROWID)
      }),
      IS_BIG_SUR_OR_UP ? this.dbAPI.getGroupImages() : [],
    ])
    const groupImagesMap: { [attachmentID: string]: string } = {}
    groupImagesRows?.forEach(([attachmentID, fileName]) => {
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

  getMessages = async (threadID: string, pagination: PaginationArg): Promise<Paginated<Message>> => {
    this.ensureDB()
    const { cursor, direction } = pagination || { cursor: null, direction: null }
    const msgRows = await this.dbAPI.getMessages(threadID, cursor, direction)
    if (direction !== 'after') msgRows.reverse()
    const msgRowIDs = msgRows.map(m => m.msgRowID)
    const msgGUIDs = msgRows.map(m => m.guid)
    const [attachmentRows, reactionRows] = msgRows.length === 0 ? [] : await Promise.all([
      this.dbAPI.getAttachments(msgRowIDs),
      this.dbAPI.getMessageReactions(msgGUIDs, threadID),
    ])
    const items = mapMessages(msgRows, attachmentRows, reactionRows, this.currentUserID)
    return {
      items,
      hasMore: msgRows.length === MESSAGES_LIMIT,
    }
  }

  searchMessages = async (typed: string, pagination: PaginationArg, threadID?: string): Promise<Paginated<Message>> => {
    this.ensureDB()
    const { cursor, direction } = pagination || { cursor: null, direction: null }
    const msgRows = await this.dbAPI.searchMessages(typed, threadID, cursor, direction)
    const msgRowIDs = msgRows.map(m => m.msgRowID)
    const msgGUIDs = msgRows.map(m => m.guid)
    const [attachmentRows, reactionRows] = msgRows.length === 0 ? [] : await Promise.all([
      this.dbAPI.getAttachments(msgRowIDs),
      this.dbAPI.getMessageReactions(msgGUIDs, threadID),
    ])
    const items = mapMessages(msgRows, attachmentRows, reactionRows, this.currentUserID, true)
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
    let newCount = 0
    while (newCount === 0) {
      await bluebird.delay(25)
      newCount = await this.dbAPI.getThreadMessagesCount(threadID) - count
    }
    return true
  }

  private sendFileFromFilePath = async (threadID: string, filePath: string) => {
    const count = await this.dbAPI.getThreadMessagesCount(threadID)
    await this.api.sendFile(threadID, filePath)
    let newCount = 0
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
    texts.log('sendReadReceipt', threadID, 'marking message as read for guid', messageID)
    if (this.enableMarkAsRead) (await this.swiftServer)?.markRead(messageID)
  }

  onThreadSelected = async (threadID: string) => {
    // we don't need to Promise.all because the Promise has already been
    // fired for swiftServer
    const swiftServer = await this.swiftServer
    if (!swiftServer) return

    if (!threadID?.startsWith('iMessage;-;')) { // ignore groups and sms threads
      swiftServer.watchThreadActivity(null)
      return
    }

    const participantID = threadID.split(';').pop()
    swiftServer.watchThreadActivity(participantID, status => {
      this.onEvent([
        {
          type: ServerEventType.USER_ACTIVITY,
          activityType: status === ActivityStatus.Typing ? ActivityType.TYPING : ActivityType.NONE,
          threadID,
          participantID,
          durationMs: 120_000,
        },
      ])
    })
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
    try {
      return await convertCGBI(buffer)
    } catch (err) {
      return 'file://' + encodeURI(filePath)
    }
  }
}
