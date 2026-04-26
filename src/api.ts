import fsSync, { promises as fs } from 'fs'
import url from 'url'
import os from 'os'
import path from 'path'
import crypto from 'crypto'
import { PlatformAPI, ServerEventType, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, MessageContent, PaginationArg, ActivityType, User, texts, ServerEvent, MessageSendOptions, PhoneNumber, GetAssetOptions, SerializedSession, ThreadFolderName, SearchMessageOptions, ThreadID, MessageID, ClientContext, PaginatedWithCursors, ThreadReminder, Awaitable, ReAuthError } from '@textshq/platform-sdk'
import pRetry from 'p-retry'
import PQueue from 'p-queue'
import urlRegex from 'url-regex'
import { setTimeout as setTimeoutAsync } from 'node:timers/promises'

import { BeeperThread } from './desktop-types'
import { convertCGBI } from './async-cgbi-to-png'
import { CHAT_DB_PATH, APP_BUNDLE_ID, TMP_MOBILE_SMS_PATH, IS_BIG_SUR_OR_UP, IS_VENTURA_OR_UP, IS_TAHOE_OR_UP, MIN_MACOS_VERSION_ERROR } from './constants'
import DatabaseAPI from './db-api'
import { csrStatus } from './csr'
import { waitForFileToExist, shellExec, threadIDToAddress, getSingleParticipantAddress } from './util'
import swiftServer, { type SwiftPlatformAPI } from './SwiftServer/lib'
import MessagesControllerWrapper from './mc'
import { makeJSONPersistence, Persistence } from './persistence'
import { appleDateToMillisSinceEpoch, makeAppleDate } from './time'
import Phaser from './phaser'
import { reviveSwiftMapperValue } from './swift-json'

if (swiftServer) swiftServer.isLoggingEnabled = texts.isLoggingEnabled

function canAccessMessagesDir() {
  try {
    const fd = fsSync.openSync(CHAT_DB_PATH, 'r')
    fsSync.closeSync(fd)
    return true
  } catch (err) { return false }
}

const TMP_ATTACHMENT_DIR_PATH = path.join(os.tmpdir(), 'texts-imessage')
const DEFAULT_THREAD_PREFIX = IS_TAHOE_OR_UP ? 'any' : 'iMessage'

const linkRegex = urlRegex()

function parseSwiftMessageAPIJSON<T>(json: string): T {
  return reviveSwiftMapperValue(JSON.parse(json)) as T
}

type SwiftGetThreadsResponse = PaginatedWithCursors<Thread> & {
  _pollingCursor?: {
    maxRowID?: number
    maxDateRead?: number
  }
}

export default class AppleiMessage implements PlatformAPI {
  constructor(public readonly accountID: string) {}

  private persistence?: Persistence

  private swiftPlatformAPI?: SwiftPlatformAPI

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

  private onEvent: OnServerEventCallback | undefined

  private getMessagesController = () =>
    MessagesControllerWrapper.get(this.swiftPlatformAPI!)

  private applyPersistedThreadState(thread: Thread): Thread {
    const archive = this.persistence?.getThreadProp(thread.id, 'archive')
    const reminder = this.persistence?.getThreadProp(thread.id, 'reminder')
    const extra: NonNullable<BeeperThread['extra']> = { ...(thread.extra ?? {}) }
    const isArchivedUpToOrder = archive?.archivedAt ? appleDateToMillisSinceEpoch(archive.archivedAt) : undefined
    if (isArchivedUpToOrder != null) {
      extra.isArchivedUpToOrder = isArchivedUpToOrder
    } else {
      delete extra.isArchivedUpToOrder
    }

    return {
      ...thread,
      extra,
      reminder,
      isPinned: this.persistence?.getThreadProp(thread.id, 'pin') === true,
      isLowPriority: this.persistence?.getThreadProp(thread.id, 'lowPriority') === true,
    }
  }

  private async ensureDB(): Promise<DatabaseAPI> {
    if (this.cachedDB) {
      return this.cachedDB
    }

    try {
      this.cachedDB = await DatabaseAPI.make()
    } catch (error: unknown) {
      texts.error("imsg: couldn't initialize DatabaseAPI:", error)
      throw new ReAuthError("Can't access iMessage data", { cause: error })
    }
    // at this point, we can definitely read the imsg database

    texts.log('imsg: created DatabaseAPI')

    this.swiftPlatformAPI = new swiftServer.PlatformAPI(this.accountID)

    if (process.env.IMESSAGE_SKIP_EAGER_MC !== '1') {
      // eslint-disable-next-line no-void
      void this.getMessagesController()
        .then(() => {
          texts.log('imsg: fetched MessagesControllerWrapper')
        })
        .catch(error => {
          texts.error('imsg: eager MessagesControllerWrapper fetch failed:', error)
        })
    }

    return this.cachedDB
  }

  private resolveThreadID = async (threadID: ThreadID): Promise<ThreadID> =>
    swiftServer.resolveThreadID(threadID)

  getCurrentUser = async (): Promise<CurrentUser> => {
    return parseSwiftMessageAPIJSON<CurrentUser>(await this.swiftPlatformAPI!.getCurrentUser())
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

  private experiments = ''

  init = async (session: SerializedSession, { dataDirPath }: ClientContext, prefs?: Record<string, any>) => {
    if (session && !IS_BIG_SUR_OR_UP) throw new Error(MIN_MACOS_VERSION_ERROR)
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
  }

  // eslint-disable-next-line class-methods-use-this
  serializeSession = () => ({})

  dispose = async () => {
    swiftServer?.stopSysPrefsOnboarding?.()
    await Promise.all([
      this.swiftPlatformAPI?.dispose(),
      fs.rm(TMP_ATTACHMENT_DIR_PATH, { recursive: true }).catch(() => {}),
      this.cachedDB?.dispose(),
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

  startEventPollingFromCurrentState = async (): Promise<void> => {
    if (!this.onEvent) throw new Error('subscribeToEvents must be called before startEventPollingFromCurrentState')
    const db = await this.ensureDB()
    await db.startPollingFromCurrentState()
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
    const swiftAPI = this.swiftPlatformAPI!
    const parsed = parseSwiftMessageAPIJSON<Thread | null>(await swiftAPI.getThread(hashedThreadID))
    return parsed ? this.applyPersistedThreadState(parsed) : undefined
  }

  createThread = async (userIDs: string[], title?: string, message?: string) => {
    if (userIDs.length === 0) return false
    if (!message?.trim()) throw Error('no message')
    if (userIDs.length === 1) {
      const address = userIDs[0]
      const existingThread = await this.getThread(DEFAULT_THREAD_PREFIX + `;-;${address}`)
      if (existingThread) {
        if (message) this.sendMessage(existingThread.id, { text: message })
        return existingThread
      }
    } else {
      // potential todo: we can search for an existing thread with the specified userIDs here
    }
    await (await this.getMessagesController()).createThread(userIDs, message)
    return true
  }

  // eslint-disable-next-line class-methods-use-this
  getUser = async (ids: { userID?: string } | { username?: string } | { phoneNumber?: PhoneNumber } | { email?: string }): Promise<User | undefined> => {
    // TODO: find if actually registered on imessage
    if ('phoneNumber' in ids) return { id: ids.phoneNumber!, phoneNumber: ids.phoneNumber }
    if ('email' in ids) return { id: ids.email!, email: ids.email }
  }

  getThreads = async (folderName: ThreadFolderName, pagination?: PaginationArg): Promise<PaginatedWithCursors<Thread>> => {
    const db = await this.ensureDB()
    const swiftAPI = this.swiftPlatformAPI!
    texts.log(`imsg/getThreads: requested folder ${folderName}, pagination: ${JSON.stringify(pagination)}`)
    if (texts.isLoggingEnabled) console.time('imsg getThreads')
    const cursor = pagination?.cursor ?? null
    const { _pollingCursor, ...response } = parseSwiftMessageAPIJSON<SwiftGetThreadsResponse>(await swiftAPI.getThreads(
      folderName,
      pagination?.cursor,
      pagination?.direction,
    ))
    if (!cursor && _pollingCursor?.maxRowID) {
      // TODO: this is a polling bootstrap side effect; it should not live in a getter/non-mutating API.
      void db.startPollingIfNecessary(_pollingCursor.maxRowID, _pollingCursor.maxDateRead ?? 0)
    }
    if (texts.isLoggingEnabled) console.timeEnd('imsg getThreads')
    return {
      ...response,
      items: response.items.map(thread => this.applyPersistedThreadState(thread)),
    }
  }

  getMessages = async (hashedThreadID: ThreadID, pagination?: PaginationArg): Promise<Paginated<Message>> => {
    const swiftAPI = this.swiftPlatformAPI!
    return parseSwiftMessageAPIJSON<Paginated<Message>>(await swiftAPI.getMessages(
      hashedThreadID,
      pagination?.cursor,
      pagination?.direction,
      undefined,
    ))
  }

  getMessage = async (hashedThreadID: ThreadID, messageID: MessageID) => {
    const swiftAPI = this.swiftPlatformAPI!
    const parsed = parseSwiftMessageAPIJSON<Message | null>(await swiftAPI.getMessage(
      hashedThreadID,
      messageID,
    ))
    return parsed ?? undefined
  }

  searchMessages = async (typed: string, pagination?: PaginationArg, options?: SearchMessageOptions): Promise<PaginatedWithCursors<Message>> => {
    const swiftAPI = this.swiftPlatformAPI!
    return parseSwiftMessageAPIJSON<PaginatedWithCursors<Message>>(await swiftAPI.searchMessages(
      typed,
      options?.threadID,
      Boolean(options?.mediaType),
      options?.sender,
      undefined,
    ))
  }

  private swiftSendQueue = new PQueue({ concurrency: 1, timeout: 45_000 })

  private swiftSendWithRetry = (threadID: ThreadID, text?: string, filePath?: string, quotedMessageID?: string) =>
    this.swiftSendQueue.add(async () => {
      const retries = quotedMessageID ? 2 : 1
      await pRetry(async () => {
        // re-fetch the controller on each attempt so that invalidation is respected
        const controller = await this.getMessagesController()
        await controller.sendMessage(threadID, text, filePath, quotedMessageID)
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
    const mc = await this.getMessagesController()
    const address = threadIDToAddress(threadID)
    if (!sentThreadIDs.every(sentThreadID => sentThreadID === threadID || (sentThreadID && mc?.isSameContact(address, threadIDToAddress(sentThreadID))))) {
      texts.error('imsg: imessage potentially sent messages to invalid thread')
      return true
    }
    const messages = (await Promise.all(sentMessageIDs.map(([, guid]) => this.getMessage(threadID, guid)))).filter(message => message != null)
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
    this.waitForMessageSend(threadID, quotedMessageID, undefined, () =>
      this.swiftSendWithRetry(threadID, undefined, filePath, quotedMessageID))

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
    const threadID = await this.resolveThreadID(hashedThreadID)
    if (threadID.startsWith('SMS;-;') && threadID.includes('@')) throw Error('Cannot send message to email address over SMS')
    // if (IS_TAHOE_OR_UP && options.quotedMessageID) throw Error('replies are not supported on macOS Tahoe')
    try {
      this.sendingMessagesCount++
      const { quotedMessageID } = options
      if (content.fileBuffer) {
        return this.sendFileFromBuffer(threadID, content.fileBuffer, content.fileName, quotedMessageID)
      }
      if (content.filePath) {
        return this.sendFileFromFilePath(threadID, content.filePath, quotedMessageID)
      }
      return this.waitForMessageSend(threadID, quotedMessageID, content.text, () => this.swiftSendWithRetry(threadID, content.text, undefined, quotedMessageID))
    } finally {
      this.sendingMessagesCount--
    }
  }

  editMessage = async (hashedThreadID: ThreadID, messageID: MessageID, content: MessageContent) => {
    const threadID = await this.resolveThreadID(hashedThreadID)
    if (!IS_VENTURA_OR_UP) throw Error('Only supported on macOS Ventura or later')
    const { text } = content
    if (!text) throw new Error('Tried to edit message to have empty content')
    const controller = await this.getMessagesController()
    await controller.editMessage(threadID, messageID, text)
    return true
  }

  // eslint-disable-next-line class-methods-use-this
  updateThread = async (hashedThreadID: ThreadID, updates: Partial<Thread>) => {
    const threadID = await this.resolveThreadID(hashedThreadID)
    if ('mutedUntil' in updates) {
      const mc = await this.getMessagesController()
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
    const threadID = await this.resolveThreadID(hashedThreadID)
    const mc = await this.getMessagesController()
    await mc.deleteThread(threadID)
  }

  sendActivityIndicator = async (type: ActivityType, hashedThreadID?: ThreadID) => {
    if (!hashedThreadID) {
      texts.error('imsg: ignoring request to send an activity indicator, no thread id provided')
      return
    }
    const threadID = await this.resolveThreadID(hashedThreadID)
    if (![ActivityType.TYPING, ActivityType.NONE].includes(type)) return
    if (this.sendingMessagesCount > 0) return texts.log('skipping sendActivityIndicator')
    // group chat typing indicators require Tahoe+
    if (!IS_TAHOE_OR_UP && !getSingleParticipantAddress(threadID)) return
    const isTyping = type === ActivityType.TYPING
    return (await this.getMessagesController()).sendTypingStatus(threadID, isTyping)
  }

  private setReaction = async (threadID: ThreadID, messageID: MessageID, reactionKey: string, on: boolean) => {
    // if (IS_TAHOE_OR_UP) throw Error('reactions are not supported on macOS Tahoe')
    await pRetry(async () => {
      const controller = await this.getMessagesController()
      const result = await this.waitForMessageSend(
        threadID,
        messageID,
        undefined,
        () => controller.setReaction(threadID, messageID, reactionKey, on),
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
    if (reactionKey === 'sticker') throw Error("Adding sticker reactions isn't supported")
    const threadID = await this.resolveThreadID(hashedThreadID)
    return this.threadPhaser.bracketed(hashedThreadID, this.setReaction(threadID, messageID, reactionKey, true))
  }

  removeReaction = async (hashedThreadID: ThreadID, messageID: MessageID, reactionKey: string) => {
    if (reactionKey === 'sticker') throw Error("Removing sticker reactions isn't supported")
    const threadID = await this.resolveThreadID(hashedThreadID)
    return this.threadPhaser.bracketed(hashedThreadID, this.setReaction(threadID, messageID, reactionKey, false))
  }

  deleteMessage = async (hashedThreadID: ThreadID, messageID: MessageID) => {
    await this.swiftPlatformAPI!.deleteMessage(hashedThreadID, messageID)
  }

  markAsUnread = (hashedThreadID: ThreadID) => this.swiftPlatformAPI!.markAsUnread(hashedThreadID)

  sendReadReceipt = async (hashedThreadID: ThreadID, messageID?: MessageID) => {
    await pRetry(async () => {
      await this.swiftPlatformAPI!.sendReadReceipt(hashedThreadID)
    }, {
      onFailedAttempt: error => {
        texts.Sentry.captureException(error)
        texts.log(`sendReadReceipt failed. Retries left: ${error.retriesLeft}`)
      },
      retries: 1,
    })
  }

  notifyAnyway = (hashedThreadID: ThreadID) => this.swiftPlatformAPI!.notifyAnyway(hashedThreadID)

  onThreadSelected = async (hashedThreadID: ThreadID) => {
    // Drop empty/null thread IDs. Beeper Desktop depends on its own vendored
    // fork of platform-sdk that lets the thread ID be null. We currently don't
    // use that fork, but we ought to.
    if (!hashedThreadID) return
    if (!this.onEvent) return

    return this.swiftPlatformAPI!.onThreadSelected(hashedThreadID, this.onEvent)
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
    askForAutomationAccess: () => swiftServer.askForAutomationAccess().then(() => true),
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
        const filePath = path.join(TMP_MOBILE_SMS_PATH, `${uuid}.mov`)
        await waitForFileToExist(filePath, 5_000)
        return url.pathToFileURL(filePath).href
      }

      case 'reaction-sticker': {
        const rowIDStr = methodName.split('.', 1)?.[0]
        const reactionRowID = Number(rowIDStr)
        if (!Number.isSafeInteger(reactionRowID)) throw new Error('invalid reaction sticker row ID')
        const filePath = await this.swiftPlatformAPI!.getAttachmentFilePath(reactionRowID)
        if (!filePath) throw new Error("couldn't resolve sticker attachment for reaction row")
        return url.pathToFileURL(filePath).href
      }

      case 'thread-image': {
        const filePath = await this.swiftPlatformAPI!.getChatImageFilePath(methodName)
        if (!filePath) throw new Error("couldn't resolve chat image attachment")
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
      const chat = await this.getThread(hashedThreadID)
      if (!chat) {
        texts.log(`imsg/archive/${hashedThreadID}: chat not found in iMessage, deleting from Beeper`)
        this.persistence?.deleteThreadProp(hashedThreadID, 'archive')
        this.onEvent?.([{
          type: ServerEventType.STATE_SYNC,
          objectName: 'thread',
          mutationType: 'delete',
          entries: [hashedThreadID],
          objectIDs: {},
        }])
        return
      }

      // Archive cutoff is `now`, not the DB's latest-message date: the renderer
      // un-archives when its cached latest-message sortKey exceeds
      // `isArchivedUpToOrder`, and its cache can outrun the DB when a message
      // was deleted for all devices (gone from `chat_message_join`) — we don't
      // observe those deletions, so `now` is the only value guaranteed to cover
      // anything still cached.
      const now = new Date()
      const newArchivalOrder = now.getTime()
      const persistedArchivedAt = makeAppleDate(now)
      texts.log(`imsg/archive/${hashedThreadID}: setting isArchivedUpToOrder=${newArchivalOrder} ("${persistedArchivedAt}")`)

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
