import fsSync, { promises as fs } from 'fs'
import url from 'url'
import os from 'os'
import path from 'path'
import crypto from 'crypto'
import { PlatformAPI, ServerEventType, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, InboxName, ReAuthError, MessageContent, PaginationArg, ActivityType, User, texts, ServerEvent, MessageSendOptions, PhoneNumber, GetAssetOptions, SerializedSession, ThreadFolderName, SearchMessageOptions, ThreadID, MessageID, ClientContext, PaginatedWithCursors } from '@textshq/platform-sdk'
import pRetry from 'p-retry'
import PQueue from 'p-queue'
import urlRegex from 'url-regex'
import { setTimeout as setTimeoutAsync } from 'timers/promises'

import { convertCGBI } from './async-cgbi-to-png'
import { mapThreads, mapMessages, mapThread, mapAccountLogin, MessageWithExtra } from './mappers'
import ASAPI from './as2'
import ThreadReadStore from './thread-read-store'
// import { trackTime } from '../../common/analytics'
import { CHAT_DB_PATH, IS_BIG_SUR_OR_UP, APP_BUNDLE_ID, TMP_MOBILE_SMS_PATH, IS_MONTEREY_OR_UP, IS_VENTURA_OR_UP, IS_SONOMA_OR_UP } from './constants'
import DatabaseAPI, { THREADS_LIMIT, MESSAGES_LIMIT } from './db-api'
import { csrStatus } from './csr'
import { waitForFileToExist, shellExec, threadIDToAddress, getSingleParticipantAddress } from './util'
import swiftServer, { ActivityStatus, MessageCell } from './SwiftServer/lib'
import MessagesControllerWrapper from './mc'
import type { AXMessageSelection, MappedAttachmentRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow } from './types'
import { threadHasher as globalThreadIDHasher, participantHasher as globalParticipantIDHasher } from './RustServer/lib'
import { hashMessage, hashParticipantID, hashThread, hashThreadID } from './hashing'

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
  currentUser: CurrentUser

  // private accountID: string

  private threadReadStore: ThreadReadStore | undefined

  private dbAPI = new DatabaseAPI(this)

  private ensureDB = () => {
    if (!this.dbAPI.connected) throw new ReAuthError('Unable to connect to iMessage database')
  }

  private asAPI = IS_BIG_SUR_OR_UP ? undefined : ASAPI()

  private onEvent: OnServerEventCallback

  private async initDB() {
    await this.dbAPI.init()
    if (this.dbAPI.connected) { // we can read the db which likely means user went through auth flow
      await this.storeCurrentUser()
      MessagesControllerWrapper.get()
    }
  }

  private storeCurrentUser = async () => {
    this.ensureDB()
    const logins = await this.dbAPI.getAccountLogins()
    const unprefixed = logins.map(mapAccountLogin).filter(Boolean)
    this.currentUser = {
      id: unprefixed[0] || 'default',
      displayText: unprefixed.join(', '),
      email: logins.find(a => a?.startsWith('E:'))?.split(':')?.[1] || undefined,
      phoneNumber: logins.find(a => a?.startsWith('P:'))?.split(':')?.[1] || undefined,
    }
  }

  getCurrentUser = (): CurrentUser => ({
    ...this.currentUser,
    id: globalParticipantIDHasher.hashAndRemember(this.currentUser.id),
  })

  login = async (): Promise<LoginResult> => {
    await this.initDB()
    if (this.dbAPI.connected) return { type: 'success' }
    return { type: 'error', errorMessage: 'Please grant access to Messages Data and try again.' }
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

  private experiments: string

  init = async (session: SerializedSession, { dataDirPath }: ClientContext, prefs: Record<string, any>) => {
    this.session = session || {}
    // this.accountID = accountID
    const userDataDirPath = path.dirname(dataDirPath)
    this.experiments = await fs.readFile(path.join(userDataDirPath, 'imessage-enabled-experiments'), 'utf-8').catch(() => '')
    if (swiftServer) {
      swiftServer.isPHTEnabled = prefs.hide_messages_app
      swiftServer.enabledExperiments = this.experiments
      texts.log('imessage enabledExperiments', swiftServer.enabledExperiments)
    }
    await this.initDB()
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
      this.dbAPI.dispose(),
      this.asAPI?.dispose(),
    ])
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
    if (swiftServer?.isMessagesAppInDock && swiftServer?.isPHTEnabled) {
      this.removeMessagesAppInDock()
    }
  }

  getThread = async (hashedThreadID: ThreadID) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    const chatRow = await this.dbAPI.getThread(threadID)
    if (!chatRow) return
    const [handleRows, lastMessageRows, unreadCounts, dndState] = await Promise.all([
      this.dbAPI.getThreadParticipants(chatRow.ROWID),
      this.dbAPI.fetchLastMessageRows(chatRow.ROWID),
      this.dbAPI.getUnreadCounts(),
      getDNDState(),
    ])
    return hashThread(mapThread(
      chatRow,
      {
        handleRowsMap: { [chatRow.guid]: handleRows },
        currentUserID: this.currentUser.id,
        threadReadStore: this.threadReadStore,
        mapMessageArgsMap: { [chatRow.guid]: lastMessageRows },
        unreadCounts,
        dndState,
      },
    ))
  }

  private catalinaCreateThread = async (userIDs: string[]) => {
    const threadID = await this.asAPI!.createThread(userIDs)
    await setTimeoutAsync(10)
    const [chatRow] = await this.dbAPI.getThreadWithWait(threadID)
    if (!chatRow) return
    const [handleRows, lastMessageRows, unreadCounts, dndState] = await Promise.all([
      this.dbAPI.getThreadParticipantsWithWait(chatRow, userIDs),
      this.dbAPI.fetchLastMessageRows(chatRow.ROWID),
      this.dbAPI.getUnreadCounts(),
      getDNDState(),
    ])
    if (handleRows.length < 1) return
    const thread = mapThread(
      chatRow,
      {
        handleRowsMap: { [chatRow.guid]: handleRows },
        currentUserID: this.currentUser.id,
        threadReadStore: this.threadReadStore,
        mapMessageArgsMap: { [chatRow.guid]: lastMessageRows },
        unreadCounts,
        dndState,
      },
    )
    if (!thread.timestamp) thread.timestamp = new Date()
    return thread
  }

  createThread = async (hashedUserIDs: string[], title?: string, message?: string) => {
    if (hashedUserIDs.length === 0) return null
    const userIDs = hashedUserIDs.map(hashedUserID => globalParticipantIDHasher.originalFromHash(hashedUserID))
    this.ensureDB()
    if (!IS_BIG_SUR_OR_UP) return this.catalinaCreateThread(userIDs)
    if (userIDs.length === 1) {
      const address = userIDs[0]
      const existingThread = await this.getThread(`iMessage;-;${address}`)
      if (existingThread) {
        if (message) this.sendMessage(existingThread.id, { text: message })
        return existingThread
      }
    } else {
      // potential todo: we can search for an existing thread with the specified userIDs here
    }
    if (!message) throw Error('no message')
    await (await MessagesControllerWrapper.get()).createThread(userIDs, message)
    return true
  }

  getUser = async (ids: { userID?: string } | { username?: string } | { phoneNumber?: PhoneNumber } | { email?: string }): Promise<User> => {
    // todo find if actually registered on imessage
    if ('phoneNumber' in ids) return { id: ids.phoneNumber, phoneNumber: ids.phoneNumber }
    if ('email' in ids) return { id: ids.email, email: ids.email }
  }

  getThreads = async (folderName: ThreadFolderName, pagination: PaginationArg): Promise<PaginatedWithCursors<Thread>> => {
    if (texts.isLoggingEnabled) console.time('imsg getThreads')
    if (folderName !== InboxName.NORMAL) {
      return {
        items: [],
        hasMore: false,
        oldestCursor: null,
      }
    }
    const { cursor, direction } = pagination || { cursor: null, direction: null }
    this.ensureDB()
    if (texts.isLoggingEnabled) console.time('imsg dbapi')
    const chatRows = await this.dbAPI.getThreads(cursor, direction)
    if (texts.isLoggingEnabled) console.timeEnd('imsg dbapi')
    const mapMessageArgsMap: { [chatGUID: string]: [MappedMessageRow[], MappedAttachmentRow[], MappedReactionMessageRow[]] } = {}
    const handleRowsMap: { [chatGUID: string]: MappedHandleRow[] } = {}
    const allMsgRows: MappedMessageRow[] = []
    if (texts.isLoggingEnabled) console.time('imsg Promise.all')
    const [, , groupImagesRows, unreadCounts, dndState] = await Promise.all([
      Promise.all(chatRows.map(async chat => {
        const [msgRows, attachmentRows, reactionRows] = await this.dbAPI.fetchLastMessageRows(chat.ROWID)
        if (!cursor) allMsgRows.push(...msgRows)
        mapMessageArgsMap[chat.guid] = [msgRows, attachmentRows, reactionRows]
      })),
      Promise.all(chatRows.map(async chat => {
        handleRowsMap[chat.guid] = await this.dbAPI.getThreadParticipants(chat.ROWID)
      })),
      IS_BIG_SUR_OR_UP ? this.dbAPI.getGroupImages() : [],
      this.dbAPI.getUnreadCounts(),
      getDNDState(),
    ])
    if (texts.isLoggingEnabled) console.timeEnd('imsg Promise.all')
    const groupImagesMap: { [attachmentID: string]: string } = {}
    groupImagesRows?.forEach(([attachmentID, fileName]) => {
      groupImagesMap[attachmentID] = fileName
    })
    if (texts.isLoggingEnabled) console.time('imsg mapThreads')
    const items = mapThreads(chatRows, { mapMessageArgsMap, handleRowsMap, groupImagesMap, dndState, unreadCounts, currentUserID: this.currentUser.id, threadReadStore: this.threadReadStore })
    if (texts.isLoggingEnabled) console.timeEnd('imsg mapThreads')
    if (!cursor) this.dbAPI.setLastCursor(allMsgRows)
    if (texts.isLoggingEnabled) console.timeEnd('imsg getThreads')
    return {
      items: items.map(hashThread),
      hasMore: chatRows.length === THREADS_LIMIT,
      oldestCursor: chatRows[chatRows.length - 1]?.msgDateString,
    }
  }

  getMessages = async (hashedThreadID: ThreadID, pagination: PaginationArg): Promise<Paginated<Message>> => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    this.ensureDB()
    const { cursor, direction } = pagination || { cursor: null, direction: null }
    const msgRows = await this.dbAPI.getMessages(threadID, cursor, direction)
    if (direction !== 'after') msgRows.reverse()
    const msgRowIDs = msgRows.map(m => m.ROWID)
    const msgGUIDs = msgRows.map(m => m.guid)
    const [attachmentRows, reactionRows] = msgRows.length === 0 ? [] : await Promise.all([
      this.dbAPI.getAttachments(msgRowIDs),
      this.dbAPI.getMessageReactions(msgGUIDs, threadID),
    ])
    const items = mapMessages(msgRows, attachmentRows, reactionRows, this.currentUser.id)
    return {
      items: items.map(hashMessage),
      hasMore: msgRows.length === MESSAGES_LIMIT,
    }
  }

  getMessage = async (hashedThreadID: ThreadID, messageID: MessageID): Promise<Message> => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    this.ensureDB()
    const [messageGUID] = messageID.split('_')
    const msgRow = await this.dbAPI.getMessage(messageGUID)
    if (!msgRow) return
    const [attachmentRows, reactionRows] = await Promise.all([
      this.dbAPI.getAttachments([msgRow.ROWID]),
      this.dbAPI.getMessageReactions([msgRow.guid], threadID),
    ])
    const items = mapMessages([msgRow], attachmentRows, reactionRows, this.currentUser.id)
    return hashMessage(items.find(i => i.id === messageID))
  }

  searchMessages = async (typed: string, pagination: PaginationArg, options: SearchMessageOptions): Promise<PaginatedWithCursors<Message>> => {
    this.ensureDB()
    const { threadID: hashedThreadID, mediaType, sender } = options
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    const { cursor, direction } = pagination || { cursor: null, direction: null }
    const mediaOnly = !!mediaType
    const msgRows = await this.dbAPI.searchMessages(typed, threadID, mediaOnly, cursor, direction, sender)
    const msgRowIDs = msgRows.map(m => m.ROWID)
    const msgGUIDs = msgRows.map(m => m.guid)
    const [attachmentRows, reactionRows] = msgRows.length === 0 ? [] : await Promise.all([
      this.dbAPI.getAttachments(msgRowIDs),
      this.dbAPI.getMessageReactions(msgGUIDs, threadID),
    ])
    const items = mapMessages(msgRows, attachmentRows, reactionRows, this.currentUser.id, true)
    return {
      items: items.map(hashMessage),
      hasMore: msgRows.length === MESSAGES_LIMIT,
      oldestCursor: msgRows[0]?.date?.toString(),
    }
  }

  private swiftSendQueue = new PQueue({ concurrency: 1, timeout: 45_000 })

  private swiftSendWithRetry = (threadID: ThreadID, text: string, filePath?: string, quotedMessageID?: string) =>
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

  private waitForMessageSend = async (threadID: ThreadID, quotedMessageID: MessageID, text: string, callback: () => Promise<void>, timeoutMs = 45_000): Promise<true | Message[]> => {
    const lastRowID = await this.dbAPI.getLastMessageRowID()
    await callback()
    let sentMessageIDs: [number, string][]
    const startTime = Date.now()
    // messages ending with links will sometimes be split with each link as a separate message (for link preview)
    const links = text?.match(linkRegex)
    const expectedNewMessageIDCount = links?.length || 1
    const waitForLinksTimeout = 1_500
    while (sentMessageIDs?.length !== expectedNewMessageIDCount) {
      sentMessageIDs = await this.dbAPI.getSentMessageIDsSince(lastRowID)
      // at least one message sent, but not `expectedNewMessageIDCount`
      if (text && sentMessageIDs.length > 0 && (Date.now() - startTime) > waitForLinksTimeout) break
      if ((Date.now() - startTime) > timeoutMs) throw Error('timed out waiting for sent messages')
      await setTimeoutAsync(25)
    }
    const getSentThreadIDs = () => Promise.all(sentMessageIDs.map(([rowID]) => this.dbAPI.getThreadIDForMessageRowID(rowID)))
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
      console.log('imessage potentially sent messages to invalid thread')
      return true
    }
    const hashedThreadID = globalThreadIDHasher.hashAndRemember(threadID)
    const messages = (await Promise.all(sentMessageIDs.map(([, guid]) => this.getMessage(hashedThreadID, guid)))).filter(Boolean)
    for (const message of messages) {
      if (!message.isHidden) {
        const intended = quotedMessageID ?? undefined
        const actual = message.linkedMessageID ?? undefined
        if (intended !== actual) {
          console.log('imessage sent message with incorrect quoted message', { intended, actual })
          texts.Sentry.captureMessage(`imessage sent message with incorrect quoted message, intended=${!!intended} actual=${!!actual}`)
        }
      }
    }
    return messages
  }

  private sendFileFromFilePath = async (threadID: ThreadID, filePath: string, quotedMessageID: MessageID): Promise<boolean | Message[]> =>
    this.waitForMessageSend(threadID, quotedMessageID, undefined, () => (
      this.asAPI
        ? this.asAPI!.sendFile(threadID, filePath)
        : this.swiftSendWithRetry(threadID, undefined, filePath, quotedMessageID)))

  private sendFileFromBuffer = async (threadID: ThreadID, fileBuffer: Buffer, mimeType: string, fileName: string, quotedMessageID?: string): Promise<boolean | Message[]> => {
    await fs.mkdir(TMP_ATTACHMENT_DIR_PATH, { recursive: true })
    const tmpFilePath = path.join(TMP_ATTACHMENT_DIR_PATH, fileName || crypto.randomUUID())
    await fs.writeFile(tmpFilePath, fileBuffer)
    const result = await this.sendFileFromFilePath(threadID, tmpFilePath, quotedMessageID)
    // we don't immediately delete the file because imessage takes an unknown amount of time to send
    return result
  }

  private sendingMessagesCount = 0

  sendMessage = async (hashedThreadID: ThreadID, content: MessageContent, options: MessageSendOptions = {}): Promise<boolean | Message[]> => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    if (threadID.startsWith('SMS;-;') && threadID.includes('@')) throw Error('Cannot send message to email address over SMS')
    try {
      this.sendingMessagesCount++
      const { quotedMessageID } = options
      if (content.fileBuffer) {
        return this.sendFileFromBuffer(threadID, content.fileBuffer, content.mimeType, content.fileName, quotedMessageID)
      }
      if (content.filePath) {
        return this.sendFileFromFilePath(threadID, content.filePath, quotedMessageID)
      }
      if (IS_BIG_SUR_OR_UP) {
        return this.waitForMessageSend(threadID, quotedMessageID, content.text, () => this.swiftSendWithRetry(threadID, content.text, undefined, quotedMessageID))
      }
      return this.waitForMessageSend(threadID, undefined, content.text, () =>
        this.asAPI!.sendTextMessage(threadID, content.text))
    } finally {
      this.sendingMessagesCount--
    }
  }

  editMessage = async (hashedThreadID: ThreadID, messageID: MessageID, content: MessageContent) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    if (!IS_VENTURA_OR_UP) throw Error('supported on ventura and above')
    const { text } = content
    const messageCell = await this.getMessageCell(threadID, messageID, false)
    const controller = await MessagesControllerWrapper.get()
    await controller.editMessage(threadID, JSON.stringify(messageCell), text)
    return true
  }

  updateThread = async (hashedThreadID: ThreadID, updates: Partial<Thread>) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    if (!IS_BIG_SUR_OR_UP) throw Error('supported on big sur and above')
    if ('mutedUntil' in updates) {
      const mc = await MessagesControllerWrapper.get()
      await mc.muteThread(threadID, updates.mutedUntil === 'forever')
    }
  }

  deleteThread = async (hashedThreadID: ThreadID) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    if (!IS_BIG_SUR_OR_UP) throw Error('supported on big sur and above')
    const mc = await MessagesControllerWrapper.get()
    await mc.deleteThread(threadID)
  }

  sendActivityIndicator = async (type: ActivityType, hashedThreadID: ThreadID) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    if (![ActivityType.TYPING, ActivityType.NONE].includes(type)) return
    if (!IS_BIG_SUR_OR_UP) throw Error('supported on big sur and above')
    if (this.sendingMessagesCount > 0) return texts.log('skipping sendActivityIndicator')
    const participantID = getSingleParticipantAddress(threadID)
    // only 1-to-1 conversations are supported
    if (!participantID) return
    const isTyping = type === ActivityType.TYPING
    return (await MessagesControllerWrapper.get()).sendTypingStatus(threadID, isTyping)
  }

  private getMessageCell = async (threadID: ThreadID, messageID: MessageID, useOverlay = true): Promise<MessageCell> => {
    // ogMessageJSON is
    // const [msgID, part] = messageID.split('_', 2)
    // const ogMessageJSON = texts.getOriginalObject?.('imessage', this.accountID!, ['message', msgID])
    // if (!ogMessageJSON) throw Error('og message not found')
    // const [msgRow, attachmentRows, currentUserID]: [MappedMessageRow, MappedAttachmentRow[], string] = JSON.parse(ogMessageJSON)
    // const messages = mapMessage(msgRow, attachmentRows, [], currentUserID)
    // const message = messages[part || 0]
    const message = await this.getMessage(globalThreadIDHasher.hashAndRemember(threadID), messageID) as MessageWithExtra
    if (!message) throw Error("couldn't find message")
    const [msgRow] = JSON.parse(message._original)
    // use overlay mode only when the message is not in a thread
    const overlay = useOverlay && IS_MONTEREY_OR_UP && !message.linkedMessageID && !message.extra?.part
    const closestMessage: AXMessageSelection = overlay
      ? { messageGUID: messageID, offset: 0, cellID: IS_SONOMA_OR_UP ? null : msgRow.balloon_bundle_id, cellRole: null }
      : await this.dbAPI.findClosestTextMessage(threadID, messageID, message, msgRow) // todo optimize by calling only if needed
    return { ...closestMessage, overlay } as MessageCell
  }

  private setReaction = async (threadID: ThreadID, messageID: MessageID, reactionKey: string, on: boolean) => {
    if (!IS_BIG_SUR_OR_UP) throw Error('supported on big sur and above')
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

  addReaction = (hashedThreadID: ThreadID, messageID: MessageID, reactionKey: string) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    this.setReaction(threadID, messageID, reactionKey, true)
  }

  removeReaction = (hashedThreadID: ThreadID, messageID: MessageID, reactionKey: string) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    this.setReaction(threadID, messageID, reactionKey, false)
  }

  deleteMessage = async (hashedThreadID: ThreadID, messageID: MessageID) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    if (!IS_VENTURA_OR_UP) throw Error('supported on ventura and above')
    const messageCell = await this.getMessageCell(threadID, messageID)
    const controller = await MessagesControllerWrapper.get()
    await controller.undoSend(threadID, JSON.stringify(messageCell))
  }

  private toggleThreadRead = (read: boolean) => async (hashedThreadID: ThreadID) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    const controller = await MessagesControllerWrapper.get()
    await controller.toggleThreadRead(threadID, read)
  }

  markAsUnread = this.toggleThreadRead(false) // ventura and up only

  sendReadReceipt = async (hashedThreadID: ThreadID, messageID: MessageID) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    if (IS_BIG_SUR_OR_UP) {
      await pRetry(async () => {
        const isRead = await this.dbAPI.isThreadRead(threadID)
        if (isRead) return
        await this.toggleThreadRead(true)(hashedThreadID)
        if (!IS_VENTURA_OR_UP) {
          await setTimeoutAsync(50)
          if (!await this.dbAPI.isThreadRead(threadID)) {
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

  notifyAnyway = async (hashedThreadID: ThreadID) => {
    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    const controller = await MessagesControllerWrapper.get()
    await controller.notifyAnyway(threadID)
  }

  private dndSet = new Set<string>()

  onThreadSelected = async (hashedThreadID: ThreadID) => {
    // Drop empty/null thread IDs. Beeper Desktop depends on its own vendored
    // fork of platform-sdk that lets the thread ID be null. We currently don't
    // use that fork, but we ought to.
    if (!hashedThreadID) return

    const threadID = globalThreadIDHasher.originalFromHash(hashedThreadID)
    if (this.experiments.includes('no_watch_thread')) return
    // we don't need to Promise.all because the Promise has already been
    // fired for messagesController
    const messagesController = await MessagesControllerWrapper.get()
    if (!messagesController) return

    // ignore groups and sms threads
    const participantID = getSingleParticipantAddress(threadID)
    // if (!participantID) {
    //   return messagesController.watchThreadActivity(null)
    // }
    texts.log('imsg thread activity: watching', hashedThreadID)

    // this can be optimized, a bunch of redundant events will be sent from swift -> js and platform-imessage -> client
    return messagesController.watchThreadActivity(threadID, statuses => {
      texts.log('imsg thread activity: received', JSON.stringify(statuses))
      const events: ServerEvent[] = [{
        type: ServerEventType.USER_ACTIVITY,
        activityType: statuses.includes(ActivityStatus.Typing) ? ActivityType.TYPING : ActivityType.NONE,
        threadID: hashThreadID(threadID),
        participantID: hashParticipantID(participantID),
        durationMs: 120_000,
      }]
      const userID = threadID.split(';', 3).pop()
      const isDNDCanNotify = statuses.includes(ActivityStatus.DNDCanNotify)
      if (statuses.includes(ActivityStatus.DND) || isDNDCanNotify) {
        this.dndSet.add(userID)
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
            status: undefined,
          },
        })
      }
      this.onEvent(events)
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
    isMessagesAppSetup: async () => {
      await this.dbAPI.init()
      return this.dbAPI!.isNotEmpty()
    },
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
  }

  getAsset = async (_: GetAssetOptions, pathHex: string, methodName: string) => {
    switch (pathHex) {
      case 'proxied': {
        const result = await this.proxiedAuthFns[methodName]()
        const json = JSON.stringify(result)
        return json === undefined ? 'null' : json
      }

      case 'hw': { // handwriting
        const [uuid] = methodName.split('.', 1)
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
        return
      }

      case 'dt': { // digital touch
        const [uuid] = methodName.split('.', 1)
        const filePath = path.join(TMP_MOBILE_SMS_PATH, `${uuid}.mov`)
        await waitForFileToExist(filePath, 5_000)
        return url.pathToFileURL(filePath).href
      }

      default: {
        const filePath = Buffer.from(pathHex, 'hex').toString()
        const buffer = await fs.readFile(filePath)
        try {
          // eslint-disable-next-line @typescript-eslint/return-await
          return await convertCGBI(buffer)
        } catch (err) {
          return url.pathToFileURL(filePath).href
        }
      }
    }
  }

  private removeMessagesAppInDock = async () => {
    await swiftServer.removeMessagesFromDock()
    await swiftServer.killDock()
  }
}
