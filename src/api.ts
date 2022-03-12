import fsSync, { promises as fs } from 'fs'
import url from 'url'
import os from 'os'
import path from 'path'
import crypto from 'crypto'
import bluebird from 'bluebird'
import childProcess from 'child_process'
import { PlatformAPI, ServerEventType, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, InboxName, ReAuthError, MessageContent, PaginationArg, ActivityType, User, AccountInfo, texts, ServerEvent, MessageSendOptions, Awaitable, PresenceMap, PhoneNumber } from '@textshq/platform-sdk'
import urlRegex from 'url-regex'
import pRetry from 'p-retry'

import { convertCGBI } from './async-cgbi-to-png'
import { mapThreads, mapMessages, mapThread, mapAccountLogin, mapMessage } from './mappers'
import ASAPI from './as2'
import ThreadReadStore from './thread-read-store'
// import { trackTime } from '../../common/analytics'
import { CHAT_DB_PATH, IS_BIG_SUR_OR_UP, APP_BUNDLE_ID, TMP_MOBILE_SMS_PATH, IS_MONTEREY_OR_UP } from './constants'
import DatabaseAPI, { THREADS_LIMIT, MESSAGES_LIMIT } from './db-api'
import { csrStatus } from './csr'
import { waitForFileToExist, shellExec } from './util'
import swiftServer, { ActivityStatus, MessagesController } from './SwiftServer/lib'
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

enum OSAError {
  // {
  //   NSLocalizedDescription = "Error: Error: An error occurred."
  //   NSLocalizedFailureReason = "Error: Error: An error occurred."
  //   OSAScriptErrorBriefMessageKey = "Error: Error: An error occurred."
  //   OSAScriptErrorMessageKey = "Error: Error: An error occurred."
  //   OSAScriptErrorNumberKey = "-1743"
  //   OSAScriptErrorRangeKey = "NSRange: {0, 0}"
  // }
  AnErrorOccurred = -1743,
  CantGetObject = -1728,
}

export default class AppleiMessage implements PlatformAPI {
  currentUserID: string

  private accountID: string

  private threadReadStore: ThreadReadStore

  private dndState = new DNDState()

  private dbAPI = new DatabaseAPI(this)

  private ensureDB = () => {
    if (!this.dbAPI.connected) throw new ReAuthError('Unable to connect to iMessage database')
  }

  private asAPI = ASAPI()

  private messagesControllerFetchPromise: Promise<MessagesController>

  private messagesControllerCreatePromise: Promise<MessagesController>

  private onEvent: OnServerEventCallback

  private filesToDelete = new Set<string>()

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

  private static singleParticipantForThread(threadID: string | null): string | null {
    if (!threadID?.startsWith('iMessage;-;')) {
      return null
    }
    return threadID.split(';', 3).pop()
  }

  init = async (_: undefined, { dataDirPath, accountID }: AccountInfo, prefs: Record<string, any>) => {
    this.accountID = accountID
    if (swiftServer) swiftServer.isPHTEnabled = prefs.hide_messages_app
    await this.dbAPI.init()
    if (this.dbAPI.connected) { // we can read the db which likely means user went through auth flow
      this.getMessagesController()
    }
    this.threadReadStore = new ThreadReadStore(path.dirname(dataDirPath))
    csrStatus().then(status => {
      texts.trackPlatformEvent({
        csrutilStatus: status,
        enabled: status.includes('enabled.'),
      })
    }).catch(console.error)
  }

  dispose = async () => {
    swiftServer.stopSysPrefsOnboarding()
    // if the promise is undefined, we probably failed to create the controller
    // and so getMessagesController() would re-initialize it. We only really care
    // about disposing any existing handle.
    await Promise.all([
      this.messagesControllerCreatePromise && (await this.getMessagesController()).dispose(),
      ...[...this.filesToDelete].map(filePath => fs.unlink(filePath).catch(() => { })),
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
    const [handleRows, lastMessageRows, dndState] = await Promise.all([
      this.dbAPI.getThreadParticipants(chatRow.ROWID),
      this.dbAPI.fetchLastMessageRows(chatRow.ROWID),
      this.dndState.get(),
    ])
    return mapThread(
      chatRow,
      {
        handleRowsMap: { [chatRow.guid]: handleRows },
        currentUserID: this.currentUserID,
        threadReadStore: this.threadReadStore,
        mapMessageArgsMap: { [chatRow.guid]: lastMessageRows },
        dndState,
      },
    )
  }

  private catalinaCreateThread = async (userIDs: string[]) => {
    const threadID = await this.asAPI.createThread(userIDs)
    await bluebird.delay(10)
    const [chatRow] = await this.dbAPI.getThreadWithWait(threadID)
    if (!chatRow) return
    const [handleRows, lastMessageRows, dndState] = await Promise.all([
      this.dbAPI.getThreadParticipantsWithWait(chatRow, userIDs),
      this.dbAPI.fetchLastMessageRows(chatRow.ROWID),
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
    if (userIDs.length === 1) {
      const address = userIDs[0]
      const existingThread = await this.getThread(`iMessage;-;${address}`)
      if (existingThread) {
        this.sendMessage(existingThread.id, { text: message })
        return existingThread
      }
      if (message) await (await this.getMessagesController()).createThread([address], message)
      else childProcess.spawn('open', [`imessage://${address}`])
    } else {
      // potential todo: we can search for an existing thread with the specified userIDs here
      await (await this.getMessagesController()).createThread(userIDs, message)
    }
  }

  getUser = async (ids: { phoneNumber?: PhoneNumber } | { email?: string }): Promise<User> => {
    // todo find if actually registered on imessage
    if ('phoneNumber' in ids) return { id: ids.phoneNumber, phoneNumber: ids.phoneNumber }
    if ('email' in ids) return { id: ids.email, email: ids.email }
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
    const [,, groupImagesRows, dndState] = await Promise.all([
      bluebird.map(chatRows, async chat => {
        const [msgRows, attachmentRows, reactionRows] = await this.dbAPI.fetchLastMessageRows(chat.ROWID)
        if (!cursor) allMsgRows.push(...msgRows)
        mapMessageArgsMap[chat.guid] = [msgRows, attachmentRows, reactionRows]
      }),
      bluebird.map(chatRows, async chat => {
        handleRowsMap[chat.guid] = await this.dbAPI.getThreadParticipants(chat.ROWID)
      }),
      IS_BIG_SUR_OR_UP ? this.dbAPI.getGroupImages() : [],
      this.dndState.get(),
    ])
    const groupImagesMap: { [attachmentID: string]: string } = {}
    groupImagesRows?.forEach(([attachmentID, fileName]) => {
      groupImagesMap[attachmentID] = fileName
    })
    const items = mapThreads(chatRows, { mapMessageArgsMap, handleRowsMap, groupImagesMap, dndState, currentUserID: this.currentUserID, threadReadStore: this.threadReadStore })
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

  private axSendWithRetry = async (threadID: string, text: string, filePath?: string, quotedMessageID?: string) => {
    const retries = quotedMessageID ? 3 : 1
    await pRetry(async () => {
      // re-fetch the controller on each attempt so that invalidation is respected
      const controller = await this.getMessagesController()
      if (quotedMessageID) {
        // todo specify id/role
        await controller.sendReply(threadID, quotedMessageID, 0, '', '', IS_MONTEREY_OR_UP, text || '', filePath || '')
      } else if (filePath) {
        await controller.sendFile(filePath, threadID)
      } else {
        await controller.sendTextMessage(text, threadID)
      }
    }, {
      onFailedAttempt: error => {
        texts.log('sendMessage failed', { quotedMessageID }, error)
        if (error.attemptNumber === (retries - 1)) {
          texts.log('second retry; force-invalidating MessagesController')
          this.forceInvalidate = true
        }
      },
      retries,
    })
  }

  sendMessage = async (threadID: string, content: MessageContent, options?: MessageSendOptions) => {
    if (content.fileBuffer) {
      return this.sendFileFromBuffer(threadID, content.fileBuffer, content.mimeType, content.fileName, options.quotedMessageID)
    }
    if (content.filePath) {
      return this.sendFileFromFilePath(threadID, content.filePath, options.quotedMessageID)
    }
    if (IS_BIG_SUR_OR_UP) {
      if (options?.quotedMessageID) {
        this.elideStopTyping = true
        await this.axSendWithRetry(threadID, content.text, undefined, options.quotedMessageID)
        return true
      }

      // has a mention or link
      if (content.text?.includes('@') || content.text?.match(urlRegex({ strict: false }))) {
        try {
          this.elideStopTyping = true
          await this.axSendWithRetry(threadID, content.text, undefined, options.quotedMessageID)
          return true
        } catch (err) {
          texts.error('could not send rich text iMessage; falling back to plaintext', err)
          texts.Sentry.captureException(err)
          // fall back to sendTextMessage
        }
      }
    }
    return this.sendTextMessage(threadID, content.text)
  }

  private waitForThreadMessageCountIncrease = async (threadID: string, callback: () => Promise<void>) => {
    const count = await this.dbAPI.getThreadMessagesCount(threadID)
    await callback()
    let newCount = 0
    const startTime = Date.now()
    while (newCount === 0) {
      await bluebird.delay(25)
      newCount = await this.dbAPI.getThreadMessagesCount(threadID) - count
      if ((Date.now() - startTime) > 60_000) return false
    }
    return true
  }

  private sendTextMessage = async (threadID: string, text: string) => {
    try {
      return await this.waitForThreadMessageCountIncrease(threadID, () =>
        this.asAPI.sendTextMessage(threadID, text))
    } catch (err) {
      if (IS_BIG_SUR_OR_UP) {
        if (err.message.includes(`= "${OSAError.AnErrorOccurred}"`) || err.message.includes(`= "${OSAError.CantGetObject}"`)) {
          await this.axSendWithRetry(threadID, text)
          return true
        }
      }
      throw err
    }
  }

  private sendFileFromFilePath = async (threadID: string, filePath: string, quotedMessageID: string) =>
    this.waitForThreadMessageCountIncrease(threadID, () => (
      // send all with AX to increase reliability
      IS_MONTEREY_OR_UP // && quotedMessageID
        ? this.axSendWithRetry(threadID, undefined, filePath, quotedMessageID)
        : this.asAPI.sendFile(threadID, filePath)))

  private sendFileFromBuffer = async (threadID: string, fileBuffer: Buffer, mimeType: string, fileName: string, quotedMessageID?: string) => {
    const tmpFilePath = path.join(os.tmpdir(), fileName || crypto.randomUUID())
    await fs.writeFile(tmpFilePath, fileBuffer)
    const result = await this.sendFileFromFilePath(threadID, tmpFilePath, quotedMessageID)
    this.filesToDelete.add(tmpFilePath) // we don't immediately delete because imessage takes an unknown amount of time to send
    return result
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
    return (await this.getMessagesController()).sendTypingStatus(isTyping, participantID)
  }

  setReaction = async (threadID: string, messageID: string, reactionKey: string, on: boolean) => {
    if (!IS_BIG_SUR_OR_UP) throw Error('Not supported on catalina or lower')
    await pRetry(async () => {
      const ogMessageJSON = texts.getOriginalObject?.('imessage', this.accountID!, ['message', messageID])
      if (!ogMessageJSON) throw Error('og message not found')
      const [msgRow, attachmentRows, currentUserID]: [MappedMessageRow, MappedAttachmentRow[], string] = JSON.parse(ogMessageJSON)
      const messages = mapMessage(msgRow, attachmentRows, [], currentUserID)
      const message = messages[messageID.split('_', 2)[1] || 0]
      // use overlay mode only when the message is not in a thread
      const overlay = IS_MONTEREY_OR_UP && !message.linkedMessageID && !message.extra?.part
      const controller = await this.getMessagesController()
      const closestMessage: AXMessageSelection = overlay
        ? { guid: messageID, offset: 0, cellID: msgRow.balloon_bundle_id, cellRole: null }
        : await this.dbAPI.findClosestTextMessage(threadID, messageID, message, msgRow) // todo optimize by calling only if needed
      await controller.setReaction(closestMessage.guid, closestMessage.offset, closestMessage.cellID || '', closestMessage.cellRole || '', overlay, reactionKey, on)
    }, {
      onFailedAttempt: error => {
        texts.log(`setReaction failed, retries left: ${error.retriesLeft}`, error)
        if (error.attemptNumber === 2) {
          texts.log('second retry; force-invalidating MessagesController')
          this.forceInvalidate = true
        }
      },
      retries: 3,
    })
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
      await pRetry(async () => {
        const controller = await this.getMessagesController()
        const messageGUID = messageID.split('_', 1)[0]
        await controller.markRead(messageGUID)
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
    const participantID = AppleiMessage.singleParticipantForThread(threadID)
    if (!participantID) {
      return messagesController.watchThreadActivity(null)
    }

    // this can be optimized, a bunch of redundant events will be sent from swift -> js and platform-imessage -> client
    return messagesController.watchThreadActivity(participantID, statuses => {
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

  proxiedAuthFns = {
    canAccessMessagesDir,
    askForAutomationAccess: () => this.asAPI.askForAutomationAccess(),
    askForMessagesDirAccess: () => swiftServer.askForMessagesDirAccess(),
    startSysPrefsOnboarding: () => swiftServer.startSysPrefsOnboarding(),
    confirmUNCPrompt: () => swiftServer.confirmUNCPrompt(),
    disableMessagesNotifications: () => swiftServer.disableNotificationsForApp('Messages'),
    stopSysPrefsOnboarding: () => swiftServer.stopSysPrefsOnboarding(),
    revokeFDA: async () => {
      await shellExec('/usr/bin/tccutil', 'reset', 'SystemPolicyAllFiles', APP_BUNDLE_ID)
      return true
    },
    revokeAll: async () => {
      await shellExec('/usr/bin/tccutil', 'reset', 'All', 'com.googlecode.iterm2')
      return true
    },
  }

  getAsset = async (_, pathHex: string, methodName: string) => {
    switch (pathHex) {
      case 'proxied': {
        const result = await this.proxiedAuthFns[methodName]()
        const json = JSON.stringify(result)
        return json === undefined ? 'null' : json
      }

      case 'hw': {
        const [uuid] = methodName.split('.', 1)
        const fileNames = await fs.readdir(TMP_MOBILE_SMS_PATH)
        let attemptsRemaining = 10
        while (attemptsRemaining--) {
          const fileName = fileNames.find(fn => fn.startsWith(`hw_${uuid}_`))
          if (!fileName) {
            await bluebird.delay(100)
            continue
          }
          const hwPath = path.join(TMP_MOBILE_SMS_PATH, fileName)
          return url.pathToFileURL(hwPath).href
        }
        return
      }

      case 'dt': {
        const [uuid] = methodName.split('.', 1)
        const filePath = path.join(TMP_MOBILE_SMS_PATH, `${uuid}.mov`)
        await waitForFileToExist(filePath, 5_000)
        return url.pathToFileURL(filePath).href
      }

      default: {
        const filePath = Buffer.from(pathHex, 'hex').toString()
        const buffer = await fs.readFile(filePath)
        try {
          return await convertCGBI(buffer)
        } catch (err) {
          return url.pathToFileURL(filePath).href
        }
      }
    }
  }
}
