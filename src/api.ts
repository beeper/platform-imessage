import fsSync, { promises as fs } from 'fs'
import { mapKeys } from 'lodash'
import url from 'url'
import os from 'os'
import path from 'path'
import crypto from 'crypto'
import { PlatformAPI, ServerEventType, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, InboxName, MessageContent, PaginationArg, ActivityType, User, texts, ServerEvent, MessageSendOptions, PhoneNumber, GetAssetOptions, SerializedSession, ThreadFolderName, SearchMessageOptions, ThreadID, MessageID, ClientContext, PaginatedWithCursors, ThreadReminder, Awaitable } from '@textshq/platform-sdk'
import pRetry from 'p-retry'
import PQueue from 'p-queue'
import urlRegex from 'url-regex'
import { setTimeout as setTimeoutAsync } from 'timers/promises'

import { ReAuthError } from '@beeper/platform-sdk'
import { BeeperMessage, BeeperThread } from './desktop-types'
import { convertCGBI } from './async-cgbi-to-png'
import { mapThreads, mapMessages, mapThread, mapAccountLogin } from './mappers'
import ASAPI from './as2'
import ThreadReadStore from './thread-read-store'
import { CHAT_DB_PATH, IS_BIG_SUR_OR_UP, APP_BUNDLE_ID, TMP_MOBILE_SMS_PATH, IS_MONTEREY_OR_UP, IS_VENTURA_OR_UP, IS_SONOMA_OR_UP, IS_TAHOE_OR_UP } from './constants'
import DatabaseAPI, { THREADS_LIMIT, MESSAGES_LIMIT } from './db-api'
import { csrStatus } from './csr'
import { waitForFileToExist, shellExec, threadIDToAddress, getSingleParticipantAddress } from './util'
import swiftServer, { ActivityStatus, MessageCell } from './SwiftServer/lib'
import MessagesControllerWrapper from './mc'
import type { AXMessageSelection, ChatRow, MappedAttachmentRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow } from './types'
import { hashMessage, hashParticipantID, hashThread, hashThreadID, originalThreadID } from './hashing'
import { makeJSONPersistence, PersistedBatchGetResults, PersistedThreadProps, Persistence } from './persistence'
import { AppleDate, appleDateNow, appleDateToMillisSinceEpoch } from './time'
import Phaser from './phaser'

if (swiftServer) swiftServer.isLoggingEnabled = texts.isLoggingEnabled || texts.IS_DEV

function canAccessMessagesDir() {
  try {
    const fd = fsSync.openSync(CHAT_DB_PATH, 'r')
    fsSync.closeSync(fd)
    return true
  } catch (err) { return false }
}

const TMP_ATTACHMENT_DIR_PATH = path.join(os.tmpdir(), 'texts-imessage')

const linkRegex = urlRegex()

function getDNDState() {
  if (!IS_BIG_SUR_OR_UP) return new Set<string>()
  const arr = swiftServer.getDNDList()
  return new Set(arr)
}
export default class AppleiMessage implements PlatformAPI {
  currentUser: CurrentUser | undefined

  // private accountID: string

  private threadReadStore?: ThreadReadStore

  private persistence?: Persistence

  // used to make archive calls wait for any pending reactions/message sends,
  // to remove flicker from e.g. sending then quickly archiving manually
  private threadPhaser = new Phaser<Thread['id']>({
    // HACK: wait an arbitrary amount of time for pending sends to be committed
    // to the database so we can use its sort order
    delayMsAfterWaiting: 50,
  })

  /**
   * We need to be constructable (and we should be able to handle our `init`
   * being called) _without_ Messages.app data access, because those things
   * always happen when the account is in the process of being added. To
   * actually propagate failure when permissions aren't granted, `login` is
   * used.
   */
  private cachedDB: DatabaseAPI | null = null

  private asAPI = IS_BIG_SUR_OR_UP ? undefined : ASAPI()

  private onEvent: OnServerEventCallback | undefined

  private async ensureDB(): Promise<DatabaseAPI> {
    if (this.cachedDB) {
      return this.cachedDB
    }

    try {
      this.cachedDB = await DatabaseAPI.make(this)
    } catch (error: unknown) {
      texts.error("imsg: couldn't initialize DatabaseAPI:", error)
      throw new ReAuthError("Can't access iMessage data", { cause: error })
    }
    // at this point, we can definitely read the imsg database

    texts.log('imsg: created DatabaseAPI')

    // eslint-disable-next-line no-void
    void MessagesControllerWrapper.get()
    texts.log('imsg: fetched MessagesControllerWrapper')
    this.currentUser = await this.fetchCurrentUser()

    return this.cachedDB
  }

  private fetchCurrentUser = async (): Promise<CurrentUser> => {
    const logins = await (await this.ensureDB()).getAccountLogins()
    const unprefixed = logins.map(mapAccountLogin).filter(Boolean)
    return {
      id: unprefixed[0] || 'default',
      displayText: unprefixed.join(', '),
      email: logins.find(a => a?.startsWith('E:'))?.split(':')?.[1] || undefined,
      phoneNumber: logins.find(a => a?.startsWith('P:'))?.split(':')?.[1] || undefined,
    }
  }

  getCurrentUser = async (): Promise<CurrentUser> => {
    await this.ensureDB()
    if (!this.currentUser) {
      throw new Error('imsg: expected current user to be loaded by now')
    }

    return {
      ...this.currentUser,
      id: hashParticipantID(this.currentUser.id),
    }
  }

  login = async (): Promise<LoginResult> => {
    try {
      await this.ensureDB()
      return { type: 'success' }
    } catch (error) {
      const errorMessage = 'Couldn’t access your Messages data. Please grant access and try again. To force access, Full Disk Access may be granted to Beeper in the “Privacy & Security” section of System Settings.'
      return { type: 'error', errorMessage }
    }
  }

  private sipEnabled = csrStatus().then(status => {
    const enabled = status.includes('enabled.')
    texts.trackPlatformEvent({
      platform: 'imessage',
      csrutilStatus: status,
      enabled,
    })
    return enabled
  }).catch(console.error)

  private session: SerializedSession

  private experiments = ''

  init = async (session: SerializedSession, { dataDirPath }: ClientContext, prefs?: Record<string, any>) => {
    this.session = session || {}
    // this.accountID = accountID
    const userDataDirPath = path.dirname(dataDirPath)
    this.experiments = await fs.readFile(path.join(userDataDirPath, 'imessage-enabled-experiments'), 'utf-8').catch(() => '')
    if (swiftServer) {
      // (DESK-13231; removed until this actually works)
      // swiftServer.isPHTEnabled = prefs?.hide_messages_app ?? false
      swiftServer.enabledExperiments = this.experiments
      texts.log('imessage enabledExperiments', swiftServer.enabledExperiments)
    }
    if (texts.IS_DEV) texts.log(`imsg: session: ${JSON.stringify(session, undefined, 2)}`)
    this.persistence = await makeJSONPersistence(path.join(userDataDirPath, 'platform-imessage.json'))
    this.threadReadStore = IS_VENTURA_OR_UP ? undefined : new ThreadReadStore(userDataDirPath)
    if (IS_VENTURA_OR_UP && !this.session.migrationVersion) {
      fs.unlink(path.join(userDataDirPath, 'imessage.json')).catch(() => {})
      this.session.migrationVersion = 1
    }
  }

  serializeSession = () => this.session

  dispose = async () => {
    swiftServer?.stopSysPrefsOnboarding?.()
    // if the promise is undefined, we probably failed to create the controller
    // and so getMessagesController() would re-initialize it. We only really care
    // about disposing any existing handle.
    await Promise.all([
      MessagesControllerWrapper.dispose(),
      fs.rm(TMP_ATTACHMENT_DIR_PATH, { recursive: true }).catch(() => {}),
      this.cachedDB?.dispose(),
      this.asAPI?.dispose(),
    ])
  }

  subscribeToEvents = async (onEvent: OnServerEventCallback): Promise<void> => {
    const db = await this.ensureDB()
    db.eventSender = (events: ServerEvent[]) => {
      const evs: ServerEvent[] = []
      events.forEach(ev => {
        if (ev.type === ServerEventType.TOAST) {
          texts.Sentry.captureMessage(`iMessage SwiftServer: ${ev.toast.text}`)
        } else {
          evs.push(ev)
        }
      })
      onEvent(evs)
    }
    this.onEvent = onEvent
    if (swiftServer?.isMessagesAppInDock && swiftServer?.isPHTEnabled) {
      this.removeMessagesAppInDock()
    }
  }

  pinThread = async (hashedThreadID: ThreadID, pinned: boolean) => {
    this.persistence?.setThreadProp(hashedThreadID, 'pin', pinned)
    this.onEvent?.([{
      type: ServerEventType.STATE_SYNC,
      objectName: 'thread',
      mutationType: 'update',
      entries: [{ id: hashedThreadID, isPinned: pinned }],
      objectIDs: {},
    }])
  }

  getThread = async (hashedThreadID: ThreadID) => {
    const db = await this.ensureDB()
    const threadID = originalThreadID(hashedThreadID)
    const chatRow = await db.getThread(threadID)
    if (!chatRow) return
    const [handleRows, lastMessageRows, unreadCounts, dndState] = await Promise.all([
      db.getThreadParticipants(chatRow.ROWID),
      db.fetchLastMessageRows(chatRow.ROWID),
      db.getUnreadCounts(),
      getDNDState(),
    ])
    return hashThread(mapThread(
      chatRow,
      {
        handleRowsMap: { [chatRow.guid]: handleRows },
        currentUserID: this.currentUser!.id,
        threadReadStore: this.threadReadStore,
        mapMessageArgsMap: { [chatRow.guid]: lastMessageRows },
        unreadCounts,
        dndState,
        reminders: { [chatRow.guid]: this.persistence?.getThreadProp(hashThreadID(chatRow.guid), 'reminder') },
        archivalStates: { [chatRow.guid]: this.persistence?.getThreadProp(hashThreadID(chatRow.guid), 'archive') },
        pinStates: { [chatRow.guid]: this.persistence?.getThreadProp(hashThreadID(chatRow.guid), 'pin') },
        lowPriorityStates: { [chatRow.guid]: this.persistence?.getThreadProp(hashThreadID(chatRow.guid), 'lowPriority') },
      },
    )) as Thread // NOTE(types): appease typescript, but we aren't actually using the texts SDK contract
  }

  private catalinaCreateThread = async (userIDs: string[]) => {
    const db = await this.ensureDB()
    const threadID = await this.asAPI!.createThread(userIDs)
    await setTimeoutAsync(10)
    const [chatRow] = await db.getThreadWithWait(threadID)
    if (!chatRow) throw new Error("couldn't find newly created thread")
    const [handleRows, lastMessageRows, unreadCounts, dndState] = await Promise.all([
      db.getThreadParticipantsWithWait(chatRow, userIDs),
      db.fetchLastMessageRows(chatRow.ROWID),
      db.getUnreadCounts(),
      getDNDState(),
    ])
    if (handleRows.length < 1) throw new Error('newly created thread had no handles')
    const thread = mapThread(
      chatRow,
      {
        handleRowsMap: { [chatRow.guid]: handleRows },
        currentUserID: this.currentUser!.id,
        threadReadStore: this.threadReadStore,
        mapMessageArgsMap: { [chatRow.guid]: lastMessageRows },
        unreadCounts,
        dndState,
        reminders: { [chatRow.guid]: this.persistence?.getThreadProp(hashThreadID(chatRow.guid), 'reminder') },
        archivalStates: { [chatRow.guid]: this.persistence?.getThreadProp(hashThreadID(chatRow.guid), 'archive') },
      },
    )
    if (!thread.timestamp) thread.timestamp = new Date()
    return thread
  }

  createThread = async (userIDs: string[], title?: string, message?: string) => {
    if (userIDs.length === 0) return false
    // NOTE(types): appease typescript, but we aren't actually using the texts SDK contract
    if (!IS_BIG_SUR_OR_UP) return (await this.catalinaCreateThread(userIDs)) as Thread
    if (userIDs.length === 1) {
      const address = userIDs[0]
      const existingThread = await this.getThread(`iMessage;-;${address}`)
      if (existingThread) {
        if (message) this.sendMessage(existingThread.id, { text: message })
        // NOTE(types): appease typescript, but we aren't actually using the texts SDK contract
        return hashThread(existingThread) as Thread
      }
    } else {
      // potential todo: we can search for an existing thread with the specified userIDs here
    }
    if (!message) throw Error('no message')
    await (await MessagesControllerWrapper.get()).createThread(userIDs, message)
    return true
  }

  // eslint-disable-next-line class-methods-use-this
  getUser = async (ids: { userID?: string } | { username?: string } | { phoneNumber?: PhoneNumber } | { email?: string }): Promise<User | undefined> => {
    // TODO: find if actually registered on imessage
    if ('phoneNumber' in ids) return { id: ids.phoneNumber!, phoneNumber: ids.phoneNumber }
    if ('email' in ids) return { id: ids.email!, email: ids.email }
  }

  private batchGetThreadPropForChatRows<P extends keyof PersistedThreadProps>(chatRows: ChatRow[], propName: P): PersistedBatchGetResults<P> | undefined {
    let values = this.persistence?.batchGetThreadProp(chatRows.map(row => hashThreadID(row.guid)), propName)
    if (values) {
      // `Persistence` works with hashed thread IDs but we often begin working
      // with chat GUIDs (PII). we are expected to go back and hash everything
      // before returning to renderer
      values = mapKeys(values, (_value, hashedThreadID) => originalThreadID(hashedThreadID))
    }
    return values
  }

  getThreads = async (folderName: ThreadFolderName, pagination?: PaginationArg): Promise<PaginatedWithCursors<Thread>> => {
    const db = await this.ensureDB()
    texts.log(`imsg/getThreads: requested folder ${folderName}, pagination: ${JSON.stringify(pagination)}`)
    if (texts.isLoggingEnabled) console.time('imsg getThreads')
    if (folderName !== InboxName.NORMAL) {
      return {
        items: [],
        hasMore: false,
        oldestCursor: '0',
      }
    }
    const cursor = pagination?.cursor ?? null
    if (texts.isLoggingEnabled) console.time('imsg dbapi')
    const chatRows = await db.getThreads(pagination)
    if (texts.isLoggingEnabled) console.timeEnd('imsg dbapi')
    const mapMessageArgsMap: { [chatGUID: string]: [MappedMessageRow[], MappedAttachmentRow[], MappedReactionMessageRow[]] } = {}
    const handleRowsMap: { [chatGUID: string]: MappedHandleRow[] } = {}
    const allMsgRows: MappedMessageRow[] = []
    if (texts.isLoggingEnabled) console.time('imsg Promise.all')
    const [, , chatImagesRows, unreadCounts, dndState] = await Promise.all([
      Promise.all(chatRows.map(async chat => {
        const [msgRows, attachmentRows, reactionRows] = await db.fetchLastMessageRows(chat.ROWID)
        if (!cursor) allMsgRows.push(...msgRows)
        mapMessageArgsMap[chat.guid] = [msgRows, attachmentRows, reactionRows]
      })),
      Promise.all(chatRows.map(async chat => {
        handleRowsMap[chat.guid] = await db.getThreadParticipants(chat.ROWID)
      })),
      IS_BIG_SUR_OR_UP ? db.getChatImages() : [],
      db.getUnreadCounts(),
      getDNDState(),
    ])
    if (texts.isLoggingEnabled) console.timeEnd('imsg Promise.all')
    const chatImagesMap: { [attachmentID: string]: string } = {}
    chatImagesRows?.forEach(([attachmentID, fileName]) => {
      chatImagesMap[attachmentID] = fileName
    })
    if (texts.isLoggingEnabled) console.time('imsg mapThreads')

    const archivalStates = this.batchGetThreadPropForChatRows(chatRows, 'archive')
    try {
      const hashedIDs = chatRows.map(row => {
        const hashedID = hashThreadID(row.guid)
        const abbreviated = hashedID.substring(0, 29)
        return `${abbreviated}[${archivalStates?.[row.guid]?.archivedAt ?? '?'}]`
      })
      texts.log(`imsg/getThreads: going to map ${JSON.stringify(pagination)} (${hashedIDs.length}) ${hashedIDs.join(', ')}`)
      // eslint-disable-next-line no-empty
    } catch (err) {
      texts.error(`imsg/getThreads: couldn't log hashed ids: ${err}`)
    }
    const items = mapThreads(chatRows, {
      mapMessageArgsMap,
      handleRowsMap,
      chatImagesMap,
      dndState,
      unreadCounts,
      currentUserID: this.currentUser!.id,
      threadReadStore: this.threadReadStore,
      reminders: this.batchGetThreadPropForChatRows(chatRows, 'reminder'),
      archivalStates,
      pinStates: this.batchGetThreadPropForChatRows(chatRows, 'pin'),
      lowPriorityStates: this.batchGetThreadPropForChatRows(chatRows, 'lowPriority'),
    })
    if (texts.isLoggingEnabled) console.timeEnd('imsg mapThreads')
    if (!cursor) db.setLastCursor(allMsgRows)
    if (texts.isLoggingEnabled) console.timeEnd('imsg getThreads')
    return {
      // NOTE(types): appease typescript, but we aren't actually using the texts SDK contract
      items: items.map(hashThread) as Thread[],
      hasMore: chatRows.length === THREADS_LIMIT,
      oldestCursor: chatRows[chatRows.length - 1]?.msgDateString,
    }
  }

  getMessages = async (hashedThreadID: ThreadID, pagination?: PaginationArg): Promise<Paginated<Message>> => {
    const db = await this.ensureDB()
    const threadID = originalThreadID(hashedThreadID)
    const msgRows = await db.getMessages(threadID, pagination)
    if (pagination?.direction !== 'after') msgRows.reverse()
    const msgRowIDs = msgRows.map(m => m.ROWID)
    const msgGUIDs = msgRows.map(m => m.guid)
    const [attachmentRows, reactionRows] = msgRows.length === 0 ? [] : await Promise.all([
      db.getAttachments(msgRowIDs),
      db.getMessageReactions(msgGUIDs, { type: 'guid', guid: threadID }),
    ])
    const items = mapMessages(msgRows, attachmentRows, reactionRows, this.currentUser!.id)
    return {
      // NOTE(types): appease typescript, but we aren't actually using the texts SDK contract
      items: items.map(hashMessage) as Message[],
      hasMore: msgRows.length === MESSAGES_LIMIT,
    }
  }

  getMessage = async (hashedThreadID: ThreadID, messageID: MessageID) => {
    const db = await this.ensureDB()
    const threadID = originalThreadID(hashedThreadID)
    const [messageGUID] = messageID.split('_')
    const msgRow = await db.getMessage(messageGUID)
    if (!msgRow) return
    const [attachmentRows, reactionRows] = await Promise.all([
      db.getAttachments([msgRow.ROWID]),
      db.getMessageReactions([msgRow.guid], { type: 'guid', guid: threadID }),
    ])
    const items = mapMessages([msgRow], attachmentRows, reactionRows, this.currentUser!.id)
    const message = items.find(i => i.id === messageID)
    // NOTE(types): appease typescript, but we aren't actually using the texts SDK contract
    return (message ? hashMessage(message) : message) as Message
  }

  searchMessages = async (typed: string, pagination?: PaginationArg, options?: SearchMessageOptions): Promise<PaginatedWithCursors<Message>> => {
    const db = await this.ensureDB()
    const hashedThreadID = options?.threadID
    const threadID = hashedThreadID ? originalThreadID(hashedThreadID) : hashedThreadID
    const mediaOnly = Boolean(options?.mediaType)

    // Use Swift to search - it properly decodes attributedBody and filters by actual message text
    // This avoids false positives from binary plist metadata (e.g., "NSString" matching "string")
    const matchingRowIDs = await swiftServer.searchMessages(typed, threadID, mediaOnly, options?.sender, MESSAGES_LIMIT)

    if (matchingRowIDs.length === 0) {
      return { items: [], hasMore: false, oldestCursor: '' }
    }

    // Fetch full message data for the matching ROWIDs
    const msgRows = await db.getMessagesByRowIDs(matchingRowIDs)

    const msgRowIDs = msgRows.map(m => m.ROWID)
    const msgGUIDs = msgRows.map(m => m.guid)
    const [attachmentRows, reactionRows] = msgRows.length === 0 ? [[], []] : await Promise.all([
      db.getAttachments(msgRowIDs),
      threadID ? db.getMessageReactions(msgGUIDs, { type: 'guid', guid: threadID }) : [],
    ])
    const items = mapMessages(msgRows, attachmentRows, reactionRows, this.currentUser!.id)
    return {
      // NOTE(types): appease typescript, but we aren't actually using the texts SDK contract
      items: items.map(hashMessage) as Message[],
      hasMore: matchingRowIDs.length === MESSAGES_LIMIT,
      oldestCursor: msgRows[0]?.date?.toString(),
    }
  }

  private swiftSendQueue = new PQueue({ concurrency: 1, timeout: 45_000 })

  private swiftSendWithRetry = (threadID: ThreadID, text?: string, filePath?: string, quotedMessageID?: string) =>
    this.swiftSendQueue.add(async () => {
      const retries = quotedMessageID ? 2 : 1
      await pRetry(async () => {
        // re-fetch the controller on each attempt so that invalidation is respected
        const controller = await MessagesControllerWrapper.get()
        const [messageGUID, offset] = quotedMessageID ? quotedMessageID.split('_') : []
        await controller.sendMessage(threadID, text, filePath, quotedMessageID ? JSON.stringify({
          messageGUID,
          offset: +offset || 0,
          // TODO: specify id/role
          cellID: null,
          cellRole: null,
          overlay: IS_MONTEREY_OR_UP,
        } as MessageCell) : undefined)
      }, {
        onFailedAttempt: error => {
          texts.Sentry.captureException(error)
          texts.log('sendMessage failed', { quotedMessageID }, error)
          if (error.attemptNumber === 1) MessagesControllerWrapper.forceInvalidate = true
        },
        retries,
      })
    })

  private waitForMessageSend = async (threadID: ThreadID, quotedMessageID: MessageID | undefined, text: string | undefined, callback: () => Promise<void>, timeoutMs = 45_000): Promise<true | Message[]> => {
    const db = await this.ensureDB()
    const lastRowID = await db.getLastMessageRowID()
    await callback()
    let sentMessageIDs: [number, string][] | undefined
    const startTime = Date.now()
    // messages ending with links will sometimes be split with each link as a separate message (for link preview)
    const links = text?.match(linkRegex)
    const expectedNewMessageIDCount = links?.length || 1
    const waitForLinksTimeout = 1_500
    while (sentMessageIDs?.length !== expectedNewMessageIDCount) {
      sentMessageIDs = await db.getSentMessageIDsSince(lastRowID)
      // at least one message sent, but not `expectedNewMessageIDCount`
      if (text && sentMessageIDs.length > 0 && (Date.now() - startTime) > waitForLinksTimeout) break
      if ((Date.now() - startTime) > timeoutMs) throw Error('timed out waiting for sent messages')
      await setTimeoutAsync(25)
    }
    const getSentThreadIDs = () => Promise.all(sentMessageIDs.map(([rowID]) => db.getThreadIDForMessageRowID(rowID)))
    let sentThreadIDs = await getSentThreadIDs()
    const start = Date.now()
    while (sentThreadIDs.some(t => !t)) {
      await setTimeoutAsync(25)
      sentThreadIDs = await getSentThreadIDs()
      if ((Date.now() - start) > 10_000) break
    }
    const mc = await MessagesControllerWrapper.get()
    const address = threadIDToAddress(threadID)
    if (!sentThreadIDs.every(sentThreadID => sentThreadID === threadID || (sentThreadID && mc?.isSameContact(address, threadIDToAddress(sentThreadID))))) {
      texts.error('imsg: imessage potentially sent messages to invalid thread')
      return true
    }
    const hashedThreadID = hashThreadID(threadID)
    const messages = (await Promise.all(sentMessageIDs.map(([, guid]) => this.getMessage(hashedThreadID, guid)))).filter(message => message != null)
    for (const message of messages) {
      if (!message.isHidden) {
        const intended = quotedMessageID ?? undefined
        const actual = message.linkedMessageID ?? undefined
        if (intended !== actual) {
          texts.error('imsg: sent message with incorrect quoted message', { intended, actual })
          texts.Sentry.captureMessage(`imessage sent message with incorrect quoted message, intended=${!!intended} actual=${!!actual}`)
        }
      }
    }
    return messages
  }

  private sendFileFromFilePath = async (threadID: ThreadID, filePath: string, quotedMessageID?: MessageID): Promise<boolean | Message[]> =>
    this.waitForMessageSend(threadID, quotedMessageID, undefined, () => (
      this.asAPI
        ? this.asAPI.sendFile(threadID, filePath)
        : this.swiftSendWithRetry(threadID, undefined, filePath, quotedMessageID)))

  private sendFileFromBuffer = async (threadID: ThreadID, fileBuffer: Buffer, fileName?: string, quotedMessageID?: string): Promise<boolean | Message[]> => {
    await fs.mkdir(TMP_ATTACHMENT_DIR_PATH, { recursive: true })
    const tmpFilePath = path.join(TMP_ATTACHMENT_DIR_PATH, fileName || crypto.randomUUID())
    await fs.writeFile(tmpFilePath, fileBuffer)
    const result = await this.sendFileFromFilePath(threadID, tmpFilePath, quotedMessageID)
    // we don't immediately delete the file because imessage takes an unknown amount of time to send
    return result
  }

  private sendingMessagesCount = 0

  sendMessage = async (hashedThreadID: ThreadID, content: MessageContent, options: MessageSendOptions = {}): Promise<boolean | Message[]> =>
    this.threadPhaser.bracketed(hashedThreadID, this.actuallySendMessage(hashedThreadID, content, options))

  private actuallySendMessage = async (hashedThreadID: ThreadID, content: MessageContent, options: MessageSendOptions = {}): Promise<boolean | Message[]> => {
    const threadID = originalThreadID(hashedThreadID)
    if (threadID.startsWith('SMS;-;') && threadID.includes('@')) throw Error('Cannot send message to email address over SMS')
    if (IS_TAHOE_OR_UP && options.quotedMessageID) throw Error('replies are not supported on macOS Tahoe')
    try {
      this.sendingMessagesCount++
      const { quotedMessageID } = options
      if (content.fileBuffer) {
        return this.sendFileFromBuffer(threadID, content.fileBuffer, content.fileName, quotedMessageID)
      }
      if (content.filePath) {
        return this.sendFileFromFilePath(threadID, content.filePath, quotedMessageID)
      }
      if (IS_BIG_SUR_OR_UP) {
        return this.waitForMessageSend(threadID, quotedMessageID, content.text, () => this.swiftSendWithRetry(threadID, content.text, undefined, quotedMessageID))
      }
      return this.waitForMessageSend(threadID, undefined, content.text, () => {
        if (!content.text) throw new Error('Cannot send empty message')
        return this.asAPI!.sendTextMessage(threadID, content.text)
      })
    } finally {
      this.sendingMessagesCount--
    }
  }

  editMessage = async (hashedThreadID: ThreadID, messageID: MessageID, content: MessageContent) => {
    const threadID = originalThreadID(hashedThreadID)
    if (!IS_VENTURA_OR_UP) throw Error('Only supported on macOS Ventura or later')
    const { text } = content
    if (!text) throw new Error('Tried to edit message to have empty content')
    const messageCell = await this.getMessageCell(threadID, messageID, false)
    const controller = await MessagesControllerWrapper.get()
    await controller.editMessage(threadID, JSON.stringify(messageCell), text)
    return true
  }

  // eslint-disable-next-line class-methods-use-this
  updateThread = async (hashedThreadID: ThreadID, updates: Partial<Thread>) => {
    const threadID = originalThreadID(hashedThreadID)
    if (!IS_BIG_SUR_OR_UP) throw new Error('Only supported on macOS Big Sur or later')
    if ('mutedUntil' in updates) {
      const mc = await MessagesControllerWrapper.get()
      await mc.muteThread(threadID, updates.mutedUntil === 'forever')
    }
    if ('isLowPriority' in updates) {
      if (updates.isLowPriority) {
        this.persistence?.setThreadProp(hashedThreadID, 'lowPriority', true)
      } else {
        this.persistence?.deleteThreadProp(hashedThreadID, 'lowPriority')
      }
    }
  }

  // eslint-disable-next-line class-methods-use-this
  deleteThread = async (hashedThreadID: ThreadID) => {
    const threadID = originalThreadID(hashedThreadID)
    if (!IS_BIG_SUR_OR_UP) throw new Error('Only supported on macOS Big Sur or later')
    const mc = await MessagesControllerWrapper.get()
    await mc.deleteThread(threadID)
  }

  sendActivityIndicator = async (type: ActivityType, hashedThreadID?: ThreadID) => {
    if (!hashedThreadID) {
      texts.error('imsg: ignoring request to send an activity indicator, no thread id provided')
      return
    }
    const threadID = originalThreadID(hashedThreadID)
    if (![ActivityType.TYPING, ActivityType.NONE].includes(type)) return
    if (!IS_BIG_SUR_OR_UP) throw new Error('Only supported on macOS Big Sur or later')
    if (this.sendingMessagesCount > 0) return texts.log('skipping sendActivityIndicator')
    const participantID = getSingleParticipantAddress(threadID)
    // only 1-to-1 conversations are supported
    if (!participantID) return
    const isTyping = type === ActivityType.TYPING
    return (await MessagesControllerWrapper.get()).sendTypingStatus(threadID, isTyping)
  }

  private getMessageCell = async (threadID: ThreadID, messageID: MessageID, useOverlay = true): Promise<MessageCell> => {
    const db = await this.ensureDB()
    // ogMessageJSON is
    // const [msgID, part] = messageID.split('_', 2)
    // const ogMessageJSON = texts.getOriginalObject?.('imessage', this.accountID!, ['message', msgID])
    // if (!ogMessageJSON) throw Error('og message not found')
    // const [msgRow, attachmentRows, currentUserID]: [MappedMessageRow, MappedAttachmentRow[], string] = JSON.parse(ogMessageJSON)
    // const messages = mapMessage(msgRow, attachmentRows, [], currentUserID)
    // const message = messages[part || 0]
    const message = await this.getMessage(hashThreadID(threadID), messageID) as BeeperMessage
    if (!message) throw Error("couldn't find message")
    if (!message._original) throw Error("couldn't find original message")

    let parsed: unknown
    if (!('_original' in message && typeof message._original === 'string')) {
      throw new Error("imsg: can't recover cell from message without original data")
    }
    try {
      parsed = JSON.parse(message._original) as unknown
    } catch (error) {
      throw new Error("imsg: can't recover cell from message, malformed original JSON", { cause: error })
    }
    if (!Array.isArray(parsed)) {
      throw new Error("imsg: can't recover cell from message; original data isn't an array")
    }
    const msgRow = parsed[0]
    if (!msgRow) {
      throw new Error("imsg: can't recover cell from message; no associated row")
    }

    // use overlay mode only when the message is not in a thread
    const overlay = useOverlay && IS_MONTEREY_OR_UP && !message.linkedMessageID && !message.extra?.part
    const closestMessage: AXMessageSelection = overlay
      ? { messageGUID: messageID, offset: 0, cellID: IS_SONOMA_OR_UP ? null : msgRow.balloon_bundle_id, cellRole: null }
      : await db.findClosestTextMessage(threadID, messageID, message, msgRow) // todo optimize by calling only if needed
    return { ...closestMessage, overlay } as MessageCell
  }

  private setReaction = async (threadID: ThreadID, messageID: MessageID, reactionKey: string, on: boolean) => {
    if (IS_TAHOE_OR_UP) throw Error('reactions are not supported on macOS Tahoe')
    if (!IS_BIG_SUR_OR_UP) throw Error('only supported on big sur and above')
    await pRetry(async () => {
      const messageCell = await this.getMessageCell(threadID, messageID)
      const controller = await MessagesControllerWrapper.get()
      const result = await this.waitForMessageSend(
        threadID,
        messageID,
        undefined,
        () => controller.setReaction(threadID, JSON.stringify(messageCell), reactionKey, on),
        5_000,
      )
      if (!result) throw Error('setReaction unknown error')
    }, {
      onFailedAttempt: error => {
        texts.Sentry.captureException(error)
        texts.log(`setReaction failed, retries left: ${error.retriesLeft}`, error)
        if (error.attemptNumber === 1) MessagesControllerWrapper.forceInvalidate = true
      },
      retries: 2,
    })
  }

  addReaction = async (hashedThreadID: ThreadID, messageID: MessageID, reactionKey: string) => {
    const threadID = originalThreadID(hashedThreadID)
    return this.threadPhaser.bracketed(hashedThreadID, this.setReaction(threadID, messageID, reactionKey, true))
  }

  removeReaction = async (hashedThreadID: ThreadID, messageID: MessageID, reactionKey: string) => {
    const threadID = originalThreadID(hashedThreadID)
    return this.threadPhaser.bracketed(hashedThreadID, this.setReaction(threadID, messageID, reactionKey, false))
  }

  deleteMessage = async (hashedThreadID: ThreadID, messageID: MessageID) => {
    const threadID = originalThreadID(hashedThreadID)
    if (!IS_VENTURA_OR_UP) throw Error('supported on ventura and above')
    const messageCell = await this.getMessageCell(threadID, messageID)
    const controller = await MessagesControllerWrapper.get()
    await controller.undoSend(threadID, JSON.stringify(messageCell))
  }

  // eslint-disable-next-line class-methods-use-this
  private toggleThreadRead = (read: boolean) => async (hashedThreadID: ThreadID) => {
    const threadID = originalThreadID(hashedThreadID)
    const controller = await MessagesControllerWrapper.get()
    await controller.toggleThreadRead(threadID, read)
  }

  markAsUnread = this.toggleThreadRead(false) // ventura and up only

  sendReadReceipt = async (hashedThreadID: ThreadID, messageID?: MessageID) => {
    const db = await this.ensureDB()
    const threadID = originalThreadID(hashedThreadID)
    if (IS_BIG_SUR_OR_UP) {
      await pRetry(async () => {
        const isRead = await db.isThreadRead(threadID)
        if (isRead) return
        await this.toggleThreadRead(true)(hashedThreadID)
        if (!IS_VENTURA_OR_UP) {
          await setTimeoutAsync(50)
          if (!await db.isThreadRead(threadID)) {
            this.threadReadStore?.markThreadRead(threadID, messageID)
            throw new Error('toggleThreadRead failed')
          }
        }
      }, {
        onFailedAttempt: error => {
          texts.Sentry.captureException(error)
          texts.log(`sendReadReceipt failed. Retries left: ${error.retriesLeft}`)
        },
        retries: 1,
      })
    } else {
      this.threadReadStore?.markThreadRead(threadID, messageID)
    }
  }

  // eslint-disable-next-line class-methods-use-this
  notifyAnyway = async (hashedThreadID: ThreadID) => {
    const threadID = originalThreadID(hashedThreadID)
    const controller = await MessagesControllerWrapper.get()
    await controller.notifyAnyway(threadID)
  }

  private dndSet = new Set<string>()

  onThreadSelected = async (hashedThreadID: ThreadID) => {
    // Drop empty/null thread IDs. Beeper Desktop depends on its own vendored
    // fork of platform-sdk that lets the thread ID be null. We currently don't
    // use that fork, but we ought to.
    if (!hashedThreadID) return

    const threadID = originalThreadID(hashedThreadID)
    if (this.experiments.includes('no_watch_thread')) return
    // we don't need to Promise.all because the Promise has already been
    // fired for messagesController
    const messagesController = await MessagesControllerWrapper.get()
    if (!messagesController) return

    // ignore groups and sms threads
    const singleParticipantID = getSingleParticipantAddress(threadID)
    // if (!participantID) {
    //   return messagesController.watchThreadActivity(null)
    // }
    texts.log(`imsg/activity/${hashedThreadID}: watching`)

    // this can be optimized, a bunch of redundant events will be sent from swift -> js and platform-imessage -> client
    return messagesController.watchThreadActivity(threadID, statuses => {
      texts.log(`imsg/activity/${hashedThreadID}: received`, JSON.stringify(statuses))

      const isDNDCanNotify = statuses.includes(ActivityStatus.DNDCanNotify)
      const userID = threadID.split(';', 3).pop() as string // .split() never returns empty array
      if (statuses.includes(ActivityStatus.DND) || isDNDCanNotify) {
        this.dndSet.add(userID)
      } else {
        this.dndSet.delete(userID)
      }

      // only sync user activity for groups
      if (!singleParticipantID) {
        texts.log(`imsg/activity/${hashedThreadID}: NOT syncing; not a single participant`, JSON.stringify(statuses))
        return
      }

      const events: ServerEvent[] = [{
        type: ServerEventType.USER_ACTIVITY,
        activityType: statuses.includes(ActivityStatus.Typing) ? ActivityType.TYPING : ActivityType.NONE,
        threadID: hashedThreadID,
        participantID: hashParticipantID(singleParticipantID),
        durationMs: 120_000,
      }]
      if (statuses.includes(ActivityStatus.DND) || isDNDCanNotify) {
        events.push({
          type: ServerEventType.USER_PRESENCE_UPDATED,
          presence: {
            userID: hashParticipantID(userID),
            status: isDNDCanNotify ? 'dnd_can_notify' : 'dnd',
          },
        })
      } else if (this.dndSet.has(userID)) {
        this.dndSet.delete(userID)
        events.push({
          type: ServerEventType.USER_PRESENCE_UPDATED,
          presence: {
            userID: hashParticipantID(userID),
            status: 'idle',
          },
        })
      }

      this.onEvent?.(events)
    })
  }

  //   private getThreadMessagesChecksum = async (threadID: ThreadID, afterCursor: string) => {
  //     const x = await this.dbAPI.db.get(`SELECT count(*) as c
  // FROM message as m
  // ${COMMON_JOINS}
  // WHERE t.guid = ?
  // AND m.date >= ?
  // ORDER BY date DESC`, [threadID, afterCursor])
  //     return x.c
  //   }

  private proxiedAuthFns = {
    isMessagesAppSetup: () => this.ensureDB().then(() => true, () => false),
    canAccessMessagesDir,
    askForAutomationAccess: () => (this.asAPI
      ? this.asAPI!.askForAutomationAccess()
      : swiftServer.askForAutomationAccess().then(() => true)),
    askForMessagesDirAccess: () => swiftServer.askForMessagesDirAccess(),
    confirmUNCPrompt: () => swiftServer.confirmUNCPrompt(),
    disableMessagesNotifications: () => {
      swiftServer.disableNotificationsForApp('Messages')
      swiftServer.disableSoundEffects()
    },
    startSysPrefsOnboarding: () => swiftServer.startSysPrefsOnboarding?.(),
    stopSysPrefsOnboarding: () => swiftServer.stopSysPrefsOnboarding?.(),
    isSIPEnabled: () => this.sipEnabled,
    revokeFDA: async () => {
      await shellExec('/usr/bin/tccutil', 'reset', 'SystemPolicyAllFiles', APP_BUNDLE_ID)
      return true
    },
    revokeAll: async () => {
      await shellExec('/usr/bin/tccutil', 'reset', 'All', 'com.googlecode.iterm2')
      return true
    },
    isNotificationsEnabledForMessages: () => swiftServer.isNotificationsEnabledForMessages,
    revealSettings: () => swiftServer.revealSettings?.(),
  } satisfies Record<string, () => Awaitable<boolean | void>>

  getAsset = async (_fetchOptions?: GetAssetOptions, ...[pathHex, methodName]: string[]) => {
    switch (pathHex) {
      case 'proxied': {
        const methodNameIsValid = (name: string): name is keyof typeof this.proxiedAuthFns =>
          Object.keys(this.proxiedAuthFns).includes(name)
        if (!methodNameIsValid(methodName)) throw new Error(`Unknown proxied method name "${methodName}"`)

        const result = await this.proxiedAuthFns[methodName]()
        const json = JSON.stringify(result)
        return json === undefined ? 'null' : json
      }

      case 'hw': { // handwriting
        const [uuid] = methodName.split('.', 1)
        if (!TMP_MOBILE_SMS_PATH) throw new Error('Can only fetch this asset on macOS Big Sur or later')
        const fileNames = await fs.readdir(TMP_MOBILE_SMS_PATH)
        let attemptsRemaining = 10
        while (attemptsRemaining--) {
          const fileName = fileNames.find(fn => fn.startsWith(`hw_${uuid}_`))
          if (!fileName) {
            await setTimeoutAsync(100)
            continue
          }
          const hwPath = path.join(TMP_MOBILE_SMS_PATH, fileName)
          return url.pathToFileURL(hwPath).href
        }
        throw new Error("Couldn't fetch handwriting asset")
      }

      case 'dt': { // digital touch
        const [uuid] = methodName.split('.', 1)
        if (!TMP_MOBILE_SMS_PATH) throw new Error('Can only fetch this asset on macOS Big Sur or later')
        const filePath = path.join(TMP_MOBILE_SMS_PATH, `${uuid}.mov`)
        await waitForFileToExist(filePath, 5_000)
        return url.pathToFileURL(filePath).href
      }

      default: {
        const filePath = Buffer.from(pathHex, 'hex').toString()
        const buffer = await fs.readFile(filePath)
        try {
          // TODO: `await import` here for laziness
          return convertCGBI(buffer)
        } catch (err) {
          return url.pathToFileURL(filePath).href
        }
      }
    }
  }

  // eslint-disable-next-line class-methods-use-this
  private removeMessagesAppInDock = () => {
    swiftServer.removeMessagesFromDock()
    swiftServer.killDock()
  }

  setThreadReminder = async (threadID: string, reminder: ThreadReminder) => {
    // `threadID` should be hashed already.
    this.persistence?.setThreadProp(threadID, 'reminder', reminder)
  }

  clearThreadReminder = async (threadID: string) => {
    // `threadID` should be hashed already.
    this.persistence?.deleteThreadProp(threadID, 'reminder')
  }

  recordThreadReminderElapsed = async (threadID: string) => {
    // `threadID` should be hashed already.
    // NOTE: This function effectively replicates the behavior of `BeeperClient#recordThreadReminderElapsed`.
    const reminder = this.persistence?.getThreadProp(threadID, 'reminder')

    // https://github.com/beeper/beeper-desktop-new/blob/8a605b41935215c0380063f71e30048c0efeb588/src/pas-server/beeper/BeeperClient.ts#L893
    if (!reminder || !reminder.remindAtMs) {
      texts.error(`imsg: can't record nonexistent reminder for ${threadID} as being elapsed`)
      return
    }

    // Update the thread's timestamp in the renderer.
    // https://github.com/beeper/beeper-desktop-new/blob/8a605b41935215c0380063f71e30048c0efeb588/src/pas-server/beeper/BeeperClient.ts#L898
    this.onEvent?.([{
      type: ServerEventType.STATE_SYNC,
      objectName: 'thread',
      mutationType: 'update',
      entries: [{ id: threadID, timestamp: new Date(reminder.remindAtMs) }],
      objectIDs: {},
    }])

    this.persistence?.setThreadProp(threadID, 'reminder', {
      ...reminder,
      userRemindedAt: Date.now(),
    })
  }

  archiveThread = async (hashedThreadID: string, archived: boolean) => {
    const db = await this.ensureDB()
    // wait for any pending message sends/reactions before archiving. the
    // phaser has an artificial delay, which was introduced in the hopes that
    // the latest message id is used
    await this.threadPhaser.waitForAnyCurrentlyPending(hashedThreadID)

    const stateSyncThread = (patch: Partial<BeeperThread>) => {
      texts.log(`imsg/archive/${hashedThreadID}: syncing thread ${hashedThreadID} with patch: ${JSON.stringify(patch)}`)
      this.onEvent?.([{
        type: ServerEventType.STATE_SYNC,
        objectName: 'thread',
        mutationType: 'update',
        entries: [{ id: hashedThreadID, ...patch }],
        objectIDs: {},
      }])
    }

    if (archived) {
      const chatGUID = originalThreadID(hashedThreadID)

      let newArchivalOrder: number | undefined
      let persistedArchivedAt: AppleDate | undefined
      const latestMessage = await db.getLatestMessage(chatGUID)
      if (latestMessage) {
        newArchivalOrder = appleDateToMillisSinceEpoch(latestMessage.dateString)
        persistedArchivedAt = latestMessage.dateString

        texts.log(`imsg/archive/${hashedThreadID}: setting isArchivedUpToOrder to latest message's order (${newArchivalOrder}, raw "apple date": ${latestMessage.dateString})`)
      } else {
        // chat is empty or we can't fetch the latest message for whatever reason;
        // just synthesize an HS order & timestamp to use
        newArchivalOrder = Date.now()
        persistedArchivedAt = appleDateNow()
        texts.log(`imsg/archive/${hashedThreadID}: chat is empty, using synthesized archival order (${newArchivalOrder}, raw "apple date": ${persistedArchivedAt})`)
      }

      this.persistence?.setThreadProp(hashedThreadID, 'archive', {
        archivedAt: persistedArchivedAt,
      })
      stateSyncThread({
        extra: {
          isArchivedUpToOrder: newArchivalOrder,
          isArchivedUpto: null,
        },
      })
    } else {
      texts.log(`imsg/archive/${hashedThreadID}: unarchiving`)

      this.persistence?.deleteThreadProp(hashedThreadID, 'archive')
      stateSyncThread({
        extra: {
          isArchivedUpToOrder: null,
          isArchivedUpto: null,
        },
      })
    }
  }
}
