import fsSync, { promises as fs } from 'fs'
import url from 'url'
import os from 'os'
import path from 'path'
import crypto from 'crypto'
import bluebird from 'bluebird'
import { PlatformAPI, ServerEventType, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, InboxName, ReAuthError, MessageContent, PaginationArg, ActivityType, User, AccountInfo, texts, ServerEvent, MessageSendOptions, PhoneNumber, GetAssetOptions, SerializedSession, ThreadFolderName } from '@textshq/platform-sdk'
import urlRegex from 'url-regex'
import pRetry from 'p-retry'
import PQueue from 'p-queue'
import { setTimeout as setTimeoutAsync } from 'timers/promises'

import { convertCGBI } from './async-cgbi-to-png'
import { mapThreads, mapMessages, mapThread, mapAccountLogin, mapMessage } from './mappers'
import ASAPI, { OSAError } from './as2'
import ThreadReadStore from './thread-read-store'
// import { trackTime } from '../../common/analytics'
import { CHAT_DB_PATH, IS_BIG_SUR_OR_UP, APP_BUNDLE_ID, TMP_MOBILE_SMS_PATH, IS_MONTEREY_OR_UP, IS_VENTURA_OR_UP } from './constants'
import DatabaseAPI, { THREADS_LIMIT, MESSAGES_LIMIT } from './db-api'
import { csrStatus } from './csr'
import { pathExists, waitForFileToExist, shellExec, threadIDToAddress, getSingleParticipantAddress } from './util'
import swiftServer, { ActivityStatus, MessageCell, MessagesController } from './SwiftServer/lib'
import DNDState from './DNDState'
import type { AXMessageSelection, MappedAttachmentRow, MappedHandleRow, MappedMessageRow, MappedReactionMessageRow } from './types'

if (swiftServer) swiftServer.isLoggingEnabled = texts.isLoggingEnabled || texts.IS_DEV
const messagesControllerClass = swiftServer?.messagesControllerClass

function canAccessMessagesDir() {
  try {
    const fd = fsSync.openSync(CHAT_DB_PATH, 'r')
    fsSync.closeSync(fd)
    return true
  } catch (err) { return false }
}

const TMP_ATTACHMENT_DIR_PATH = path.join(os.tmpdir(), 'texts-imessage')

export default class AppleiMessage implements PlatformAPI {
  currentUserID: string

  private accountID: string

  private threadReadStore: ThreadReadStore | undefined

  private dndState = new DNDState()

  private dbAPI = new DatabaseAPI(this)

  private ensureDB = () => {
    if (!this.dbAPI.connected) throw new ReAuthError('Unable to connect to iMessage database')
  }

  private asAPI = ASAPI()

  private messagesControllerFetchPromise: Promise<MessagesController>

  private messagesControllerCreatePromise: Promise<MessagesController>

  private onEvent: OnServerEventCallback

  private forceInvalidate = false

  getCurrentUser = async (): Promise<CurrentUser> => {
    this.ensureDB()
    const logins = await this.dbAPI.getAccountLogins()
    const accounts = logins.map(mapAccountLogin).filter(Boolean)
    const [firstAccount] = accounts || []
    this.currentUserID = firstAccount || 'default'
    return {
      id: this.currentUserID,
      displayText: accounts.join(', '),
      // phone #s will likely not be present in account_login
      ...(firstAccount && (firstAccount.includes('@') ? { email: firstAccount } : { phoneNumber: firstAccount })),
    }
  }

  login = async (): Promise<LoginResult> => {
    await this.dbAPI.init()
    if (this.dbAPI.connected) return { type: 'success' }
    return { type: 'error', errorMessage: 'Please grant access to Messages Data and try again.' }
  }

  // here be dragons
  private getMessagesController = async (attempt = 0): Promise<MessagesController> => {
    if (!IS_BIG_SUR_OR_UP) return

    // we want to reuse existing instances of the fetch promise while any one is
    // running, but once it's done the next call to getMessagesController should
    // start up a new invocation (so that isValid() is checked again)
    //
    // the create promise, meanwhile, should be recreated sparingly: only if a previous
    // create() call failed, or inside the fetch promise when isValid is false (in either
    // case, the main fetchPromsie closure will throw and be caught by the catch)
    if (!this.messagesControllerFetchPromise) {
      this.messagesControllerFetchPromise = (async () => {
        if (!this.messagesControllerCreatePromise) {
          texts.log('creating MessagesController...')
          this.messagesControllerCreatePromise = messagesControllerClass.create()
        }
        const controller = await this.messagesControllerCreatePromise
        if (!(await controller.isValid()) || this.forceInvalidate) {
          texts.trackPlatformEvent({
            platform: 'imessage',
            message: 'disposing MessagesController',
            forceInvalidate: this.forceInvalidate,
          })
          this.forceInvalidate = false
          controller.dispose()
          throw new Error('MessagesController is invalid')
        }
        return controller
      })().finally(() => {
        // this `finally` must run *before* the catch since the catch recurses
        // getMessagesController, and when that happens the fetch promise should
        // already be undefined
        this.messagesControllerFetchPromise = undefined
      }).catch(err => {
        // we always unset createPromise here, but only auto-retry up to twice.
        // This means that a single call to getMessagesController() will spawn
        // at most three create() calls, but if all three fail then a future call
        // to getMessagesController() can spawn up to three more again
        this.messagesControllerCreatePromise = undefined
        texts.error('[imessage] getMessagesController', err)
        if (attempt > 2) {
          texts.Sentry.captureException(err, { tags: { platform: 'imessage' } })
          throw err
        }
        texts.log('retrying...')
        return this.getMessagesController(attempt + 1)
      })
    }
    return this.messagesControllerFetchPromise
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

  init = async (session: SerializedSession, { dataDirPath, accountID }: AccountInfo, prefs: Record<string, any>) => {
    this.session = session || {}
    this.accountID = accountID
    const userDataDirPath = path.dirname(dataDirPath)
    if (swiftServer) {
      swiftServer.isPHTEnabled = prefs.hide_messages_app
      swiftServer.enabledExperiments = await pathExists(path.join(userDataDirPath, 'imessage-enabled-experiments')) ? 'true' : ''
      texts.log('imessage enabledExperiments', swiftServer.enabledExperiments)
    }
    await this.dbAPI.init()
    if (this.dbAPI.connected) { // we can read the db which likely means user went through auth flow
      this.getMessagesController()
    }
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
      this.messagesControllerCreatePromise && (await this.getMessagesController()).dispose(),
      fs.rm(TMP_ATTACHMENT_DIR_PATH, { recursive: true }).catch(() => {}),
      this.dbAPI.dispose(),
      this.asAPI.dispose(),
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
  }

  searchUsers = (typed: string): User[] => []

  getThread = async (threadID: string) => {
    const chatRow = await this.dbAPI.getThread(threadID)
    if (!chatRow) return
    const [handleRows, lastMessageRows, unreadChatRowIDs, dndState] = await Promise.all([
      this.dbAPI.getThreadParticipants(chatRow.ROWID),
      this.dbAPI.fetchLastMessageRows(chatRow.ROWID),
      this.dbAPI.getUnreadChatRowIDs(),
      this.dndState.get(),
    ])
    return mapThread(
      chatRow,
      {
        handleRowsMap: { [chatRow.guid]: handleRows },
        currentUserID: this.currentUserID,
        threadReadStore: this.threadReadStore,
        mapMessageArgsMap: { [chatRow.guid]: lastMessageRows },
        unreadChatRowIDs,
        dndState,
      },
    )
  }

  private catalinaCreateThread = async (userIDs: string[]) => {
    const threadID = await this.asAPI.createThread(userIDs)
    await setTimeoutAsync(10)
    const [chatRow] = await this.dbAPI.getThreadWithWait(threadID)
    if (!chatRow) return
    const [handleRows, lastMessageRows, unreadChatRowIDs, dndState] = await Promise.all([
      this.dbAPI.getThreadParticipantsWithWait(chatRow, userIDs),
      this.dbAPI.fetchLastMessageRows(chatRow.ROWID),
      this.dbAPI.getUnreadChatRowIDs(),
      this.dndState.get(),
    ])
    if (handleRows.length < 1) return
    const thread = mapThread(
      chatRow,
      {
        handleRowsMap: { [chatRow.guid]: handleRows },
        currentUserID: this.currentUserID,
        threadReadStore: this.threadReadStore,
        mapMessageArgsMap: { [chatRow.guid]: lastMessageRows },
        unreadChatRowIDs,
        dndState,
      },
    )
    if (!thread.timestamp) thread.timestamp = new Date()
    return thread
  }

  createThread = async (userIDs: string[], title?: string, message?: string) => {
    if (userIDs.length === 0) return null
    this.ensureDB()
    if (!IS_BIG_SUR_OR_UP) return this.catalinaCreateThread(userIDs)
    if (!message) throw Error('no message')
    if (userIDs.length === 1) {
      const address = userIDs[0]
      const existingThread = await this.getThread(`iMessage;-;${address}`)
      if (existingThread) {
        this.sendMessage(existingThread.id, { text: message })
        return existingThread
      }
    } else {
      // potential todo: we can search for an existing thread with the specified userIDs here
    }
    await (await this.getMessagesController()).createThread(userIDs, message)
    return true
  }

  getUser = async (ids: { userID?: string } | { username?: string } | { phoneNumber?: PhoneNumber } | { email?: string }): Promise<User> => {
    // todo find if actually registered on imessage
    if ('phoneNumber' in ids) return { id: ids.phoneNumber, phoneNumber: ids.phoneNumber }
    if ('email' in ids) return { id: ids.email, email: ids.email }
  }

  getThreads = async (folderName: ThreadFolderName, pagination: PaginationArg): Promise<Paginated<Thread>> => {
    if (texts.isLoggingEnabled) console.time('imsg getThreads')
    if (folderName !== InboxName.NORMAL) {
      return {
        items: [],
        hasMore: false,
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
    const [, , groupImagesRows, unreadChatRowIDs, dndState] = await Promise.all([
      bluebird.map(chatRows, async chat => {
        const [msgRows, attachmentRows, reactionRows] = await this.dbAPI.fetchLastMessageRows(chat.ROWID)
        if (!cursor) allMsgRows.push(...msgRows)
        mapMessageArgsMap[chat.guid] = [msgRows, attachmentRows, reactionRows]
      }),
      bluebird.map(chatRows, async chat => {
        handleRowsMap[chat.guid] = await this.dbAPI.getThreadParticipants(chat.ROWID)
      }),
      IS_BIG_SUR_OR_UP ? this.dbAPI.getGroupImages() : [],
      this.dbAPI.getUnreadChatRowIDs(),
      this.dndState.get(),
    ])
    if (texts.isLoggingEnabled) console.timeEnd('imsg Promise.all')
    const groupImagesMap: { [attachmentID: string]: string } = {}
    groupImagesRows?.forEach(([attachmentID, fileName]) => {
      groupImagesMap[attachmentID] = fileName
    })
    if (texts.isLoggingEnabled) console.time('imsg mapThreads')
    const items = mapThreads(chatRows, { mapMessageArgsMap, handleRowsMap, groupImagesMap, dndState, unreadChatRowIDs, currentUserID: this.currentUserID, threadReadStore: this.threadReadStore })
    if (texts.isLoggingEnabled) console.timeEnd('imsg mapThreads')
    if (!cursor) this.dbAPI.setLastCursor(allMsgRows)
    if (texts.isLoggingEnabled) console.timeEnd('imsg getThreads')
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
    const msgRowIDs = msgRows.map(m => m.ROWID)
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

  getMessage = async (threadID: string, messageID: string): Promise<Message> => {
    this.ensureDB()
    const msgRow = await this.dbAPI.getMessage(threadID, messageID)
    if (!msgRow) return
    const [attachmentRows, reactionRows] = await Promise.all([
      this.dbAPI.getAttachments([msgRow.ROWID]),
      this.dbAPI.getMessageReactions([msgRow.guid], threadID),
    ])
    const items = mapMessages([msgRow], attachmentRows, reactionRows, this.currentUserID)
    return items.find(i => i.id === messageID)
  }

  searchMessages = async (typed: string, pagination: PaginationArg, threadID?: string): Promise<Paginated<Message>> => {
    this.ensureDB()
    const { cursor, direction } = pagination || { cursor: null, direction: null }
    const msgRows = await this.dbAPI.searchMessages(typed, threadID, cursor, direction)
    const msgRowIDs = msgRows.map(m => m.ROWID)
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

  private axSendQueue = new PQueue({ concurrency: 1, timeout: 60_000 })

  private axSendWithRetry = (threadID: string, text: string, filePath?: string, quotedMessageID?: string) =>
    this.axSendQueue.add(async () => {
      this.elideStopTyping = true
      const retries = quotedMessageID ? 2 : 1
      await pRetry(async () => {
        // re-fetch the controller on each attempt so that invalidation is respected
        const controller = await this.getMessagesController()
        await controller.sendMessage(threadID, text, filePath, quotedMessageID ? JSON.stringify({
          messageGUID: quotedMessageID,
          offset: 0,
          // TODO: specify id/role
          cellID: null,
          cellRole: null,
          overlay: IS_MONTEREY_OR_UP,
        } as MessageCell) : undefined)
      }, {
        onFailedAttempt: error => {
          texts.Sentry.captureException(error)
          texts.log('sendMessage failed', { quotedMessageID }, error)
          if (error.attemptNumber === 1) this.forceInvalidate = true
        },
        retries,
      })
    })

  private waitForMessageSend = async (threadID: string, quotedMessageID: string, callback: () => Promise<void>, timeoutMs = 60_000): Promise<boolean | Message[]> => {
    const lastRowID = await this.dbAPI.getLastMessageRowID()
    await callback()
    let sentMessageIDs: [number, string][]
    const startTime = Date.now()
    while (!sentMessageIDs?.length) {
      sentMessageIDs = await this.dbAPI.getSentMessageIDsSince(lastRowID)
      if ((Date.now() - startTime) > timeoutMs) return false
      await setTimeoutAsync(25)
    }
    // messages ending with links will be split into 2
    if (sentMessageIDs.length > 2) {
      // shouldn't happen
      texts.Sentry.captureMessage(`imessage: more than two sent messages: ${sentMessageIDs.length}`)
      return true
    }
    const getSentThreadIDs = () => Promise.all(sentMessageIDs.map(([rowID]) => this.dbAPI.getThreadIDForMessageRowID(rowID)))
    let sentThreadIDs = await getSentThreadIDs()
    if (sentThreadIDs.some(t => !t)) {
      await setTimeoutAsync(25)
      sentThreadIDs = await getSentThreadIDs()
    }
    const mc = await this.getMessagesController()
    const address = threadIDToAddress(threadID)
    if (!sentThreadIDs.every(sentThreadID => sentThreadID === threadID || mc?.isSameContact(address, threadIDToAddress(sentThreadID)))) {
      throw Error('potentially sent messages to invalid thread')
    }
    const messages = await Promise.all(sentMessageIDs.map(([, guid]) => this.getMessage(threadID, guid)))
    for (const message of messages) {
      const intended = quotedMessageID ?? undefined
      const actual = message.linkedMessageID ?? undefined
      if (intended !== actual) {
        console.log('imessage sent message with incorrect quoted message', { intended, actual })
        texts.Sentry.captureMessage(`imessage sent message with incorrect quoted message, intended=${!!intended} actual=${!!actual}`)
      }
    }
    return messages
  }

  private sendTextMessageWithAS = (threadID: string, text: string): Promise<boolean | Message[]> =>
    this.waitForMessageSend(threadID, undefined, () =>
      this.asAPI.sendTextMessage(threadID, text))

  private sendFileFromFilePath = async (threadID: string, filePath: string, quotedMessageID: string): Promise<boolean | Message[]> =>
    this.waitForMessageSend(threadID, quotedMessageID, () => (
      // send all with AX to increase reliability
      IS_MONTEREY_OR_UP // && quotedMessageID
      // quotedMessageID
        // TODO fix on Big Sur this would send attachments without quoting
        ? this.axSendWithRetry(threadID, undefined, filePath, quotedMessageID)
        : this.asAPI.sendFile(threadID, filePath)))

  private sendFileFromBuffer = async (threadID: string, fileBuffer: Buffer, mimeType: string, fileName: string, quotedMessageID?: string): Promise<boolean | Message[]> => {
    await fs.mkdir(TMP_ATTACHMENT_DIR_PATH, { recursive: true })
    const tmpFilePath = path.join(TMP_ATTACHMENT_DIR_PATH, fileName || crypto.randomUUID())
    await fs.writeFile(tmpFilePath, fileBuffer)
    const result = await this.sendFileFromFilePath(threadID, tmpFilePath, quotedMessageID)
    // we don't immediately delete the file because imessage takes an unknown amount of time to send
    return result
  }

  sendMessage = async (threadID: string, content: MessageContent, options: MessageSendOptions = {}): Promise<boolean | Message[]> => {
    const { quotedMessageID } = options
    if (content.fileBuffer) {
      return this.sendFileFromBuffer(threadID, content.fileBuffer, content.mimeType, content.fileName, quotedMessageID)
    }
    if (content.filePath) {
      return this.sendFileFromFilePath(threadID, content.filePath, quotedMessageID)
    }
    if (IS_BIG_SUR_OR_UP) {
      if (quotedMessageID) {
        return this.waitForMessageSend(threadID, quotedMessageID, () => this.axSendWithRetry(threadID, content.text, undefined, quotedMessageID))
      }

      // has a mention or link
      if (content.text?.includes('@') || content.text?.match(urlRegex({ strict: false }))) {
        try {
          const result = await this.waitForMessageSend(threadID, quotedMessageID, () => this.axSendWithRetry(threadID, content.text, undefined, quotedMessageID))
          return result
        } catch (err) {
          texts.error('could not send rich text iMessage; falling back to plaintext', err)
          texts.Sentry.captureException(err)
          // fall back to sendTextMessage
        }
      }
    }
    try {
      // eslint-disable-next-line @typescript-eslint/return-await
      return await this.sendTextMessageWithAS(threadID, content.text)
    } catch (err) {
      if (IS_BIG_SUR_OR_UP) {
        if (Object.values(OSAError).some(no => err.message.includes(`OSAScriptErrorNumberKey = "${no}"`))) {
          return this.waitForMessageSend(threadID, quotedMessageID, () => this.axSendWithRetry(threadID, content.text))
        }
      }
      throw err
    }
  }

  updateThread = async (threadID: string, updates: Partial<Thread>) => {
    if (!IS_BIG_SUR_OR_UP) return
    if ('mutedUntil' in updates) {
      const mc = await this.getMessagesController()
      await mc.muteThread(threadID, updates.mutedUntil === 'forever')
    }
  }

  deleteThread = async (threadID: string) => {
    if (!IS_BIG_SUR_OR_UP) return
    const mc = await this.getMessagesController()
    await mc.deleteThread(threadID)
  }

  private elideStopTyping = false

  sendActivityIndicator = async (type: ActivityType, threadID: string) => {
    if (![ActivityType.TYPING, ActivityType.NONE].includes(type)) return
    if (!IS_BIG_SUR_OR_UP) throw Error('not supported on catalina or lower')
    const participantID = getSingleParticipantAddress(threadID)
    // only 1-to-1 conversations are supported
    if (!participantID) return
    const isTyping = type === ActivityType.TYPING
    if (!isTyping) {
      this.elideStopTyping = false
      await setTimeoutAsync(100)
      if (this.elideStopTyping) {
        texts.log('Stop typing elided')
        this.elideStopTyping = false
        return
      }
    }
    return (await this.getMessagesController()).sendTypingStatus(threadID, isTyping)
  }

  private setReaction = async (threadID: string, messageID: string, reactionKey: string, on: boolean) => {
    if (!IS_BIG_SUR_OR_UP) throw Error('Not supported on catalina or lower')
    await pRetry(async () => {
      const ogMessageJSON = texts.getOriginalObject?.('imessage', this.accountID!, ['message', messageID])
      if (!ogMessageJSON) throw Error('og message not found')
      const [msgRow, attachmentRows, currentUserID]: [MappedMessageRow, MappedAttachmentRow[], string] = JSON.parse(ogMessageJSON)
      const messages = mapMessage(msgRow, attachmentRows, [], currentUserID)
      const message = messages[messageID.split('_', 2)[1] || 0]
      // use overlay mode only when the message is not in a thread
      const overlay = IS_MONTEREY_OR_UP && !message.linkedMessageID && !message.extra?.part
      const closestMessage: AXMessageSelection = overlay
        ? { messageGUID: messageID, offset: 0, cellID: msgRow.balloon_bundle_id, cellRole: null }
        : await this.dbAPI.findClosestTextMessage(threadID, messageID, message, msgRow) // todo optimize by calling only if needed
      const controller = await this.getMessagesController()
      await controller.setReaction(threadID, JSON.stringify({ ...closestMessage, overlay } as MessageCell), reactionKey, on)
    }, {
      onFailedAttempt: error => {
        texts.Sentry.captureException(error)
        texts.log(`setReaction failed, retries left: ${error.retriesLeft}`, error)
        if (error.attemptNumber === 1) this.forceInvalidate = true
      },
      retries: 2,
    })
  }

  addReaction = (threadID: string, messageID: string, reactionKey: string) =>
    this.setReaction(threadID, messageID, reactionKey, true)

  removeReaction = (threadID: string, messageID: string, reactionKey: string) =>
    this.setReaction(threadID, messageID, reactionKey, false)

  // deleteMessage = async (threadID: string, messageID: string) => false

  private toggleThreadRead = (read: boolean) => async (threadID: string) => {
    const controller = await this.getMessagesController()
    await controller.toggleThreadRead(threadID, read)
  }

  markAsUnread = this.toggleThreadRead(false) // ventura and up only

  sendReadReceipt = async (threadID: string, messageID: string) => {
    if (IS_BIG_SUR_OR_UP) {
      await pRetry(async () => {
        const isRead = await this.dbAPI.isThreadRead(threadID)
        if (isRead) return
        await this.toggleThreadRead(true)(threadID)
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

  notifyAnyway = async (threadID: string) => {
    const controller = await this.getMessagesController()
    await controller.notifyAnyway(threadID)
  }

  private dndSet = new Set<string>()

  onThreadSelected = async (threadID: string) => {
    // we don't need to Promise.all because the Promise has already been
    // fired for messagesController
    const messagesController = await this.getMessagesController()
    if (!messagesController) return

    // ignore groups and sms threads
    const participantID = getSingleParticipantAddress(threadID)
    if (!participantID) {
      return messagesController.watchThreadActivity(null)
    }

    // this can be optimized, a bunch of redundant events will be sent from swift -> js and platform-imessage -> client
    return messagesController.watchThreadActivity(threadID, statuses => {
      const events: ServerEvent[] = [{
        type: ServerEventType.USER_ACTIVITY,
        activityType: statuses.includes(ActivityStatus.Typing) ? ActivityType.TYPING : ActivityType.NONE,
        threadID,
        participantID,
        durationMs: 120_000,
      }]
      const userID = threadID.split(';', 3).pop()
      const isDNDCanNotify = statuses.includes(ActivityStatus.DNDCanNotify)
      if (statuses.includes(ActivityStatus.DND) || isDNDCanNotify) {
        this.dndSet.add(userID)
        events.push({
          type: ServerEventType.USER_PRESENCE_UPDATED,
          presence: {
            userID,
            status: isDNDCanNotify ? 'dnd_can_notify' : 'dnd',
          },
        })
      } else if (this.dndSet.has(userID)) {
        this.dndSet.delete(userID)
        events.push({
          type: ServerEventType.USER_PRESENCE_UPDATED,
          presence: {
            userID,
            status: undefined,
          },
        })
      }
      this.onEvent(events)
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

  private proxiedAuthFns = {
    isMessagesAppSetup: async () => {
      await this.dbAPI.init()
      return !await this.dbAPI?.isEmpty()
    },
    canAccessMessagesDir,
    askForAutomationAccess: () => this.asAPI.askForAutomationAccess(),
    askForMessagesDirAccess: () => swiftServer.askForMessagesDirAccess(),
    confirmUNCPrompt: () => swiftServer.confirmUNCPrompt(),
    disableMessagesNotifications: () => swiftServer.disableNotificationsForApp('Messages'),
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
}
