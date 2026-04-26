import { promises as fs } from 'fs'
import os from 'os'
import path from 'path'
import crypto from 'crypto'
import { setTimeout as setTimeoutAsync } from 'node:timers/promises'
import { PlatformAPI, ServerEventType, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, MessageContent, PaginationArg, ActivityType, User, texts, ServerEvent, MessageSendOptions, PhoneNumber, GetAssetOptions, SerializedSession, ThreadFolderName, SearchMessageOptions, ThreadID, MessageID, ClientContext, PaginatedWithCursors, ThreadReminder, Awaitable, ReAuthError } from '@textshq/platform-sdk'

import { BeeperThread } from './desktop-types'
import { APP_BUNDLE_ID, IS_BIG_SUR_OR_UP, MIN_MACOS_VERSION_ERROR } from './constants'
import { csrStatus } from './csr'
import { shellExec } from './util'
import swiftServer, { type SwiftPlatformAPI } from './SwiftServer/lib'
import { makeJSONPersistence, Persistence } from './persistence'
import { appleDateToMillisSinceEpoch, makeAppleDate } from './time'
import Phaser from './phaser'
import { reviveSwiftMapperValue } from './swift-json'

if (swiftServer) swiftServer.isLoggingEnabled = texts.isLoggingEnabled

const TMP_ATTACHMENT_DIR_PATH = path.join(os.tmpdir(), 'texts-imessage')

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
  private hasValidatedMessagesDatabaseAccess = false

  private onEvent: OnServerEventCallback | undefined

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

  private async ensureSwiftPlatformAPI(): Promise<SwiftPlatformAPI> {
    if (!this.swiftPlatformAPI) {
      this.swiftPlatformAPI = new swiftServer.PlatformAPI(this.accountID)
    }

    if (this.hasValidatedMessagesDatabaseAccess) {
      return this.swiftPlatformAPI
    }

    try {
      await swiftServer.validateDatabaseAccess()
      this.hasValidatedMessagesDatabaseAccess = true
    } catch (error: unknown) {
      texts.error("imsg: couldn't validate Messages database access:", error)
      throw new ReAuthError("Can't access iMessage data", { cause: error })
    }

    // at this point, we can definitely read the imsg database
    texts.log('imsg: validated Messages database access')

    return this.swiftPlatformAPI
  }

  private hasAttemptedToStartPoller = false

  private async startPollingIfNecessary(maxRowID: number, maxDateRead: number) {
    if (this.hasAttemptedToStartPoller) return
    this.hasAttemptedToStartPoller = true

    // HACK: We only get the callback via `subscribeToEvents`, but we may be
    // asked to start polling from `getThreads` first. Wait until it arrives.
    let spins = 0
    while (!this.onEvent) {
      if (++spins === 50) {
        texts.log("imsg: WARNING: still don't have server event callback after 5 seconds; something is running amok")
      }
      await setTimeoutAsync(100)
    }

    texts.log(`imsg: kicking off poller (max row id: ${maxRowID}, max date read: ${maxDateRead})`)
    // FIXME: it's useless to make these `BigInt`s when they're already `number` (lost precision)
    swiftServer.startPolling(this.onEvent, BigInt(maxRowID), BigInt(maxDateRead))
  }

  private resolveThreadID = async (threadID: ThreadID): Promise<ThreadID> =>
    swiftServer.resolveThreadID(threadID)

  getCurrentUser = async (): Promise<CurrentUser> => {
    const swiftAPI = this.swiftPlatformAPI!
    return parseSwiftMessageAPIJSON<CurrentUser>(await swiftAPI.getCurrentUser())
  }

  login = async (): Promise<LoginResult> => {
    try {
      await this.ensureSwiftPlatformAPI()
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
    swiftServer?.cancelPollingIfNecessary?.()
    await Promise.all([
      this.swiftPlatformAPI?.dispose(),
      fs.rm(TMP_ATTACHMENT_DIR_PATH, { recursive: true }).catch(() => {}),
    ])
  }

  subscribeToEvents = async (onEvent: OnServerEventCallback): Promise<void> => {
    await this.ensureSwiftPlatformAPI()
    this.onEvent = (events: ServerEvent[]) => {
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
    if (swiftServer?.isMessagesAppInDock && swiftServer?.isPHTEnabled) {
      this.removeMessagesAppInDock()
    }
  }

  startEventPollingFromCurrentState = async (): Promise<void> => {
    if (!this.onEvent) throw new Error('subscribeToEvents must be called before startEventPollingFromCurrentState')
    await this.ensureSwiftPlatformAPI()
    await swiftServer.startPollingFromCurrentState(this.onEvent)
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
    const swiftAPI = this.swiftPlatformAPI!
    const result = parseSwiftMessageAPIJSON<Thread | boolean>(await swiftAPI.createThread(userIDs, title, message))
    return typeof result === 'object' ? this.applyPersistedThreadState(result) : result
  }

  // eslint-disable-next-line class-methods-use-this
  getUser = async (ids: { userID?: string } | { username?: string } | { phoneNumber?: PhoneNumber } | { email?: string }): Promise<User | undefined> => {
    // TODO: find if actually registered on imessage
    if ('phoneNumber' in ids) return { id: ids.phoneNumber!, phoneNumber: ids.phoneNumber }
    if ('email' in ids) return { id: ids.email!, email: ids.email }
  }

  getThreads = async (folderName: ThreadFolderName, pagination?: PaginationArg): Promise<PaginatedWithCursors<Thread>> => {
    const swiftAPI = await this.ensureSwiftPlatformAPI()
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
      void this.startPollingIfNecessary(_pollingCursor.maxRowID, _pollingCursor.maxDateRead ?? 0)
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

  private sendFileFromFilePath = async (threadID: ThreadID, filePath: string, quotedMessageID?: MessageID): Promise<boolean | Message[]> =>
    parseSwiftMessageAPIJSON<boolean | Message[]>(await this.swiftPlatformAPI!.sendMessage(threadID, undefined, filePath, quotedMessageID))

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
      return parseSwiftMessageAPIJSON<boolean | Message[]>(await this.swiftPlatformAPI!.sendMessage(threadID, content.text, undefined, quotedMessageID))
    } finally {
      this.sendingMessagesCount--
    }
  }

  editMessage = async (hashedThreadID: ThreadID, messageID: MessageID, content: MessageContent) => {
    this.swiftPlatformAPI!.editMessage(hashedThreadID, messageID, content.text)
    return true
  }

  updateThread = async (hashedThreadID: ThreadID, updates: Partial<Thread>) => {
    if ('mutedUntil' in updates) {
      await this.swiftPlatformAPI!.updateThread(hashedThreadID, updates.mutedUntil === 'forever')
    }
    if ('isLowPriority' in updates) {
      if (updates.isLowPriority) {
        this.persistence?.setThreadProp(hashedThreadID, 'lowPriority', true)
      } else {
        this.persistence?.deleteThreadProp(hashedThreadID, 'lowPriority')
      }
    }
  }

  deleteThread = (hashedThreadID: ThreadID) => this.swiftPlatformAPI!.deleteThread(hashedThreadID)

  sendActivityIndicator = (type: ActivityType, hashedThreadID?: ThreadID) =>
    this.swiftPlatformAPI!.sendActivityIndicator(type, hashedThreadID, this.sendingMessagesCount)

  addReaction = async (hashedThreadID: ThreadID, messageID: MessageID, reactionKey: string) =>
    this.threadPhaser.bracketed(hashedThreadID, this.swiftPlatformAPI!.setReaction(hashedThreadID, messageID, reactionKey, true))

  removeReaction = async (hashedThreadID: ThreadID, messageID: MessageID, reactionKey: string) =>
    this.threadPhaser.bracketed(hashedThreadID, this.swiftPlatformAPI!.setReaction(hashedThreadID, messageID, reactionKey, false))

  deleteMessage = async (hashedThreadID: ThreadID, messageID: MessageID) => {
    const swiftAPI = this.swiftPlatformAPI!
    await swiftAPI.deleteMessage(hashedThreadID, messageID)
  }

  markAsUnread = (hashedThreadID: ThreadID) => this.swiftPlatformAPI!.markAsUnread(hashedThreadID)

  sendReadReceipt = (hashedThreadID: ThreadID, messageID?: MessageID) =>
    this.swiftPlatformAPI!.sendReadReceipt(hashedThreadID)

  notifyAnyway = (hashedThreadID: ThreadID) => this.swiftPlatformAPI!.notifyAnyway(hashedThreadID)

  onThreadSelected = async (hashedThreadID: ThreadID) => {
    // Drop empty/null thread IDs. Beeper Desktop depends on its own vendored
    // fork of platform-sdk that lets the thread ID be null. We currently don't
    // use that fork, but we ought to.
    if (!hashedThreadID) return
    if (!this.onEvent) return

    const swiftAPI = this.swiftPlatformAPI!
    return swiftAPI.onThreadSelected(hashedThreadID, this.onEvent)
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
    isMessagesAppSetup: () => this.ensureSwiftPlatformAPI().then(() => true, () => false),
    canAccessMessagesDir: () => swiftServer.canAccessMessagesDir().then(() => true, () => false),
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
    if (pathHex === 'proxied') {
      const methodNameIsValid = (name: string): name is keyof typeof this.proxiedAuthFns =>
        Object.keys(this.proxiedAuthFns).includes(name)
      if (!methodNameIsValid(methodName)) throw new Error(`Unknown proxied method name "${methodName}"`)

      const result = await this.proxiedAuthFns[methodName]()
      const json = JSON.stringify(result)
      return json === undefined ? 'null' : json
    }

    return this.swiftPlatformAPI!.getAsset(pathHex, methodName)
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
