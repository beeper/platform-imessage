import { promises as fs } from 'fs'
import os from 'os'
import path from 'path'
import bluebird from 'bluebird'
import { v4 as uuid } from 'uuid'
import { PlatformAPI, ServerEventType, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, InboxName, ReAuthError, MessageContent, PaginationArg, ActivityType, User, AccountInfo, texts, ServerEvent, MessageSendOptions } from '@textshq/platform-sdk'
import urlRegex from 'url-regex'
import pRetry from 'p-retry'

import { convertCGBI } from './async-cgbi-to-png'
import { mapThreads, mapMessages, mapThread, mapAccountLogin, MessageWithExtra } from './mappers'
import iMessageAPI from './as2'
import ThreadReadStore from './thread-read-store'
// import { trackTime } from '../../common/analytics'
import { IS_BIG_SUR_OR_UP } from './constants'
import DatabaseAPI, { THREADS_LIMIT, MESSAGES_LIMIT } from './db-api'
import { csrStatus } from './csr'
import __swiftServer, { ActivityStatus } from './SwiftServer/lib'
import type { MappedAttachmentRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow } from './types'

export default class AppleiMessage implements PlatformAPI {
  currentUserID: string

  private threadReadStore: ThreadReadStore

  private dbAPI = new DatabaseAPI(this)

  private ensureDB = () => {
    if (!this.dbAPI.connected) throw new ReAuthError('Unable to connect to iMessage database')
  }

  private api = iMessageAPI()

  private _swiftServer: Promise<typeof __swiftServer>

  private onEvent: OnServerEventCallback

  private filesToDelete = new Set<string>()

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

  private getSwiftServer = async () => {
    if (!IS_BIG_SUR_OR_UP) return
    if (this._swiftServer) {
      try {
        return await this._swiftServer
      } catch (err) {
        texts.error('[imessage] getSwiftServer', err)
        // fallthrough
      }
    }
    // if _swiftServer is undefined/rejected, try creating it again
    this._swiftServer = (async () => {
      try {
        await __swiftServer.init(texts.isLoggingEnabled || texts.IS_DEV)
        return __swiftServer
      } catch (err) {
        texts.Sentry.captureException(err, { tags: { platform: 'imessage' } })
        texts.error('[imessage] initSwiftServer', err)
        throw err
      }
    })()
    // Note: since the swiftServer promise can be rejected without immediately
    // beind handled, Node logs an unhandled promise rejection warning, but it's
    // a false alarm since the next call to this function would throw the error
    return this._swiftServer
  }

  private static singleParticipantForThread(threadID: string | null): string | null {
    if (!threadID?.startsWith('iMessage;-;')) {
      return null
    }
    return threadID.split(';', 3).pop()
  }

  init = async (_: undefined, { dataDirPath }: AccountInfo) => {
    await this.dbAPI.init()
    if (this.dbAPI.connected) { // we have FDA which means user went through auth flow
      this.getSwiftServer()
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
    this._swiftServer?.then(s => s.dispose())
    this.api.dispose()
    this.filesToDelete.forEach(filePath => {
      fs.unlink(filePath).catch(() => {})
    })
    return this.dbAPI.dispose()
  }

  subscribeToEvents = (onEvent: OnServerEventCallback): void => {
    this.dbAPI.startPolling((events: ServerEvent[]) => {
      const evs: ServerEvent[] = []
      events.forEach(ev => {
        if (ev.type === ServerEventType.TOAST) {
          texts.Sentry.captureMessage(`iMessage RustServer: ${ev.toast.text}`)
        } else {
          evs.push(ev)
        }
      })
      onEvent(evs)
    })
    this.onEvent = onEvent
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
        mapMessageArgsMap: { [chatRow.guid]: await this.dbAPI.fetchLastMessageRows(chatRow.ROWID) },
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
          mapMessageArgsMap: { [chatRow.guid]: await this.dbAPI.fetchLastMessageRows(chatRow.ROWID) },
        },
      )
    }
  }

  createThread = async (userIDs: string[], title?: string, message?: string) => {
    if (userIDs.length === 0) return null
    this.ensureDB()
    if (!IS_BIG_SUR_OR_UP) return this.catalinaCreateThread(userIDs)
    if (userIDs.length === 1) {
      const address = userIDs[0]
      const existingThread = await this.getThread(`iMessage;-;${address}`)
      if (existingThread) return existingThread
      await (await this.getSwiftServer()).createThread([address], message)
    } else {
      // potential todo: we can search for an existing thread with the specified userIDs here
      await (await this.getSwiftServer()).createThread(userIDs, message)
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
    let msgRows = await this.dbAPI.getMessages(threadID, cursor, direction)
    /**
     * imessage has a quirk where is_read is initially 1 and updated to 0
     * ck_record_id is initially null with is_read=1 and changed to an empty string with is_read=0
     */
    if (msgRows.some(row => row.ck_record_id === null)) {
      await bluebird.delay(100)
      msgRows = await this.dbAPI.getMessages(threadID, cursor, direction)
    }
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

  sendMessage = async (threadID: string, content: MessageContent, options?: MessageSendOptions) => {
    if (content.fileBuffer) {
      return this.sendFileFromBuffer(threadID, content.fileBuffer, content.mimeType, content.fileName)
    }
    if (content.filePath) {
      return this.sendFileFromFilePath(threadID, content.filePath)
    }
    if (IS_BIG_SUR_OR_UP) {
      if (options?.quotedMessageID) {
        this.elideStopTyping = true
        const server = await this.getSwiftServer()
        await server.sendReply(options.quotedMessageID, content.text)
        return true
      }

      if (content.text?.includes('@') || content.text?.match(urlRegex({ strict: false }))) {
        try {
          this.elideStopTyping = true
          const server = await this.getSwiftServer()
          await server.sendTextMessage(content.text, threadID)
          return true
        } catch (err) {
          texts.error('could not send message with swift server', err)
          // fall back to sendTextMessage
        }
      }
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
    this.filesToDelete.add(tmpFilePath) // we don't immediately delete because imessage takes an unknown amount of time to send
    return result
  }

  private elideStopTyping = false

  sendActivityIndicator = async (type: ActivityType, threadID: string) => {
    if (![ActivityType.TYPING, ActivityType.NONE].includes(type)) return
    if (!IS_BIG_SUR_OR_UP) throw Error('not supported on catalina or lower')
    const participantID = AppleiMessage.singleParticipantForThread(threadID)
    // only 1-to-1 conversations are supported
    if (!participantID) return
    const isTyping = type === ActivityType.TYPING
    if (!isTyping) {
      this.elideStopTyping = false
      await bluebird.delay(100)
      if (this.elideStopTyping) {
        texts.log('Stop typing elided')
        this.elideStopTyping = false
        return
      }
    }
    return (await this.getSwiftServer()).sendTypingStatus(isTyping, participantID)
  }

  setReaction = async (threadID: string, messageID: string, reactionKey: string, on: boolean) => {
    if (!IS_BIG_SUR_OR_UP) throw Error('not supported on catalina or lower')
    const closestMessage = await this.dbAPI.findClosestTextMessage(threadID, messageID) // todo optimize by calling only if needed
    await (await this.getSwiftServer()).setReaction(closestMessage.guid, closestMessage.offset, reactionKey, on)
  }

  addReaction = (threadID: string, messageID: string, reactionKey: string) =>
    this.setReaction(threadID, messageID, reactionKey, true)

  removeReaction = (threadID: string, messageID: string, reactionKey: string) =>
    this.setReaction(threadID, messageID, reactionKey, false)

  deleteMessage = async (threadID: string, messageID: string) => true

  sendReadReceipt = async (threadID: string, messageID: string) => {
    texts.log('sendReadReceipt', threadID, 'marking message as read for guid', messageID)
    this.threadReadStore.markThreadRead(threadID, messageID)
    if (IS_BIG_SUR_OR_UP) {
      const server = await this.getSwiftServer()
      await pRetry(async () => {
        await server.markRead(messageID)
        await bluebird.delay(100)
        if (!(await this.dbAPI.isThreadRead(threadID))) {
          throw new Error('sendReadReceipt failed (cause unknown)')
        }
      }, {
        onFailedAttempt: error => {
          texts.log(`sendReadReceipt failed. Retries left: ${error.retriesLeft}`)
        },
        retries: 1,
      })
    }
  }

  onThreadSelected = async (threadID: string) => {
    // we don't need to Promise.all because the Promise has already been
    // fired for swiftServer
    const swiftServer = await this.getSwiftServer()
    if (!swiftServer) return

    // ignore groups and sms threads
    const participantID = AppleiMessage.singleParticipantForThread(threadID)
    if (!participantID) {
      return swiftServer.watchThreadActivity(null)
    }

    return swiftServer.watchThreadActivity(participantID, status => {
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
