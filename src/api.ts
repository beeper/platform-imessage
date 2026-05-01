import { promises as fs } from 'fs'
import path from 'path'
import { PlatformAPI, ServerEventType, OnServerEventCallback, Paginated, Thread, LoginResult, Message, CurrentUser, MessageContent, PaginationArg, ActivityType, User, texts, ServerEvent, MessageSendOptions, PhoneNumber, GetAssetOptions, SerializedSession, ThreadFolderName, SearchMessageOptions, ThreadID, MessageID, ClientContext, PaginatedWithCursors, ThreadReminder, Awaitable, ReAuthError } from '@textshq/platform-sdk'

import { BeeperThread } from './desktop-types'
import { APP_BUNDLE_ID } from './constants'
import { IS_BIG_SUR_OR_UP, MIN_MACOS_VERSION_ERROR } from './common-constants'
import { csrStatus } from './csr'
import { shellExec } from './util'
import imessage, { type NativeMacPermissionAuthStatus, type NativePlatformAPI } from './IMessage/lib'
import { makeJSONPersistence, Persistence } from './persistence'
import { appleDateToMillisSinceEpoch, makeAppleDate } from './time'
import { parseSwiftMessageAPIJSON } from './swift-json'

imessage.isLoggingEnabled = texts.isLoggingEnabled

export default class AppleiMessage implements PlatformAPI {
  constructor(public readonly accountID: string) {}

  private persistence?: Persistence

  private swiftPlatformAPI?: NativePlatformAPI

  private onEvent: OnServerEventCallback | undefined

  private eventWatchingStarted = false

  private eventWatchingStartInFlight?: Promise<void>

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

  private async ensureDB() {
    try {
      await imessage.validateDatabaseAccess()
    } catch (error: unknown) {
      texts.error("imsg: couldn't validate Messages database access:", error)
      throw new ReAuthError("Can't access iMessage data", { cause: error })
    }
    // at this point, we can definitely read the imsg database
    texts.log('imsg: validated Messages database access')
  }

  getCurrentUser = async (): Promise<CurrentUser> => {
    const swiftAPI = this.swiftPlatformAPI!
    return parseSwiftMessageAPIJSON<CurrentUser>(await swiftAPI.getCurrentUser())
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
    imessage.enabledExperiments = this.experiments
    texts.log('imessage enabledExperiments', imessage.enabledExperiments)
    texts.log('imessage useSecondaryMessagesInstance', imessage.useSecondaryMessagesInstance)
    if (texts.IS_DEV) texts.log(`imsg: session: ${JSON.stringify(session, undefined, 2)}`)
    this.persistence = await makeJSONPersistence(path.join(userDataDirPath, 'platform-imessage.json'))
    this.swiftPlatformAPI ??= new imessage.PlatformAPI(this.accountID)
  }

  // eslint-disable-next-line class-methods-use-this
  serializeSession = () => ({})

  dispose = async () => {
    await this.swiftPlatformAPI?.dispose()
  }

  subscribeToEvents = async (onEvent: OnServerEventCallback): Promise<void> => {
    this.onEvent = (events: ServerEvent[]) => {
      const evs: ServerEvent[] = []
      events.forEach(ev => {
        if (ev.type === ServerEventType.TOAST) {
          texts.Sentry.captureMessage(`iMessage: ${ev.toast.text}`)
        } else {
          evs.push(ev)
        }
      })
      onEvent(evs)
    }
    imessage.setEventCallback(this.onEvent)
  }

  startEventWatchingFromCurrentState = async (): Promise<void> => {
    if (this.eventWatchingStarted) return
    if (this.eventWatchingStartInFlight) return this.eventWatchingStartInFlight
    this.eventWatchingStartInFlight = imessage.startEventWatchingFromCurrentState()
      .then(() => {
        this.eventWatchingStarted = true
      })
      .finally(() => {
        this.eventWatchingStartInFlight = undefined
      })
    return this.eventWatchingStartInFlight
  }

  private startEventWatchingAfterInitialThreads = async (): Promise<void> => {
    if (!this.onEvent || this.eventWatchingStarted) return
    await this.startEventWatchingFromCurrentState().catch(error => {
      texts.error('imsg: event watching startup failed:', error)
    })
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
    texts.log(`imsg/getThreads: requested folder ${folderName}, pagination: ${JSON.stringify(pagination)}`)
    if (texts.isLoggingEnabled) console.time('imsg getThreads')
    const response = parseSwiftMessageAPIJSON<PaginatedWithCursors<Thread>>(await this.swiftPlatformAPI!.getThreads(
      folderName,
      pagination,
    ))
    if (texts.isLoggingEnabled) console.timeEnd('imsg getThreads')
    if (folderName === 'normal' && !pagination?.cursor) {
      await this.startEventWatchingAfterInitialThreads()
    }
    return {
      ...response,
      items: response.items.map(thread => this.applyPersistedThreadState(thread)),
    }
  }

  getMessages = async (hashedThreadID: ThreadID, pagination?: PaginationArg): Promise<Paginated<Message>> => {
    const swiftAPI = this.swiftPlatformAPI!
    return parseSwiftMessageAPIJSON<Paginated<Message>>(await swiftAPI.getMessages(
      hashedThreadID,
      pagination,
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

  getOriginalObject = async (objName: 'thread' | 'message', objectID: ThreadID | MessageID): Promise<string> =>
    this.swiftPlatformAPI!.getOriginalObject(objName, objectID)

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

  private sendFileFromBuffer = async (threadID: ThreadID, fileBuffer: Buffer, fileName?: string, quotedMessageID?: string): Promise<boolean | Message[]> =>
    parseSwiftMessageAPIJSON<boolean | Message[]>(await this.swiftPlatformAPI!.sendFileFromBuffer(threadID, fileBuffer, fileName, quotedMessageID))

  private sendingMessagesCount = 0

  sendMessage = async (hashedThreadID: ThreadID, content: MessageContent, options: MessageSendOptions = {}): Promise<boolean | Message[]> => {
    // if (IS_TAHOE_OR_UP && options.quotedMessageID) throw Error('replies are not supported on macOS Tahoe')
    try {
      this.sendingMessagesCount++
      const { quotedMessageID } = options
      if (content.fileBuffer) {
        return this.sendFileFromBuffer(hashedThreadID, content.fileBuffer, content.fileName, quotedMessageID)
      }
      if (content.filePath) {
        return this.sendFileFromFilePath(hashedThreadID, content.filePath, quotedMessageID)
      }
      return parseSwiftMessageAPIJSON<boolean | Message[]>(await this.swiftPlatformAPI!.sendMessage(hashedThreadID, content.text, undefined, quotedMessageID))
    } finally {
      this.sendingMessagesCount--
    }
  }

  editMessage = async (hashedThreadID: ThreadID, messageID: MessageID, content: MessageContent) => {
    await this.swiftPlatformAPI!.editMessage(hashedThreadID, messageID, content.text)
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

  sendActivityIndicator = async (type: ActivityType, hashedThreadID?: ThreadID) => {
    if (this.sendingMessagesCount > 0) return
    return this.swiftPlatformAPI!.sendActivityIndicator(type, hashedThreadID)
  }

  addReaction = async (hashedThreadID: ThreadID, messageID: MessageID, reactionKey: string) =>
    this.swiftPlatformAPI!.addReaction(hashedThreadID, messageID, reactionKey)

  removeReaction = async (hashedThreadID: ThreadID, messageID: MessageID, reactionKey: string) =>
    this.swiftPlatformAPI!.removeReaction(hashedThreadID, messageID, reactionKey)

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

  private proxiedAuthFns = {
    isMessagesAppSetup: () => imessage.validateDatabaseAccess().then(() => true, () => false),
    canAccessMessagesDir: () => imessage.canAccessMessagesDir().then(() => true, () => false),
    askForAutomationAccess: () => imessage.askForAutomationAccess().then(() => true),
    askForMessagesDirAccess: () => imessage.askForMessagesDirAccess(),
    getAccessibilityAuthStatus: () => imessage.MacPermissions.getAuthStatus('accessibility'),
    getContactsAuthStatus: () => imessage.MacPermissions.getAuthStatus('contacts'),
    getFullDiskAccessAuthStatus: () => imessage.MacPermissions.getAuthStatus('full-disk-access'),
    askForContactsAccess: () => imessage.MacPermissions.askForContactsAccess(),
    askForFullDiskAccess: () => imessage.MacPermissions.askForFullDiskAccess(),
    confirmUNCPrompt: () => imessage.confirmUNCPrompt(),
    disableMessagesNotifications: () => imessage.disableMessagesNotifications(),
    startSysPrefsOnboarding: () => imessage.SystemSettingsOnboarding.start(),
    stopSysPrefsOnboarding: () => imessage.SystemSettingsOnboarding.stop(),
    isSIPEnabled: () => this.sipEnabled,
    revokeFDA: async () => {
      await shellExec('/usr/bin/tccutil', 'reset', 'SystemPolicyAllFiles', APP_BUNDLE_ID)
      return true
    },
    revokeAll: async () => {
      await shellExec('/usr/bin/tccutil', 'reset', 'All', 'com.googlecode.iterm2')
      return true
    },
    isNotificationsEnabledForMessages: () => imessage.isNotificationsEnabledForMessages,
    revealSettings: () => imessage.revealSettings?.(),
  } satisfies Record<string, () => Awaitable<boolean | NativeMacPermissionAuthStatus | void>>

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
