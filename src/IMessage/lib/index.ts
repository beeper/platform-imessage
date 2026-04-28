import path from 'node:path'
import nodeModule from 'node:module'
import type { MessageID, OnServerEventCallback, PaginationArg, PlatformAPI, ThreadFolderName, ThreadID, UserID } from '@textshq/platform-sdk'

import { ARCH_BINARIES_DIR_PATH } from '../../constants'

export type NativeMacPermissionAuthStatus = 'authorized' | 'denied' | 'restricted' | 'not determined'
export type NativeMacPermissionAuthType = 'accessibility' | 'contacts' | 'full-disk-access'

type PlatformAPIMethod<Name extends keyof PlatformAPI> = NonNullable<PlatformAPI[Name]>
type NativeVoidPlatformAPIMethod<Name extends keyof PlatformAPI> =
  PlatformAPIMethod<Name> extends (...args: infer Args) => unknown
    ? (...args: Args) => Promise<void>
    : never

export declare class NativePlatformAPI {
  constructor(accountID: string)

  getCurrentUser: () => Promise<string>

  searchMessages: (
    typed: string,
    threadID: ThreadID | undefined,
    mediaOnly: boolean | undefined,
    sender: 'me' | UserID | undefined,
    limit?: number,
  ) => Promise<string>

  getThreads: (
    folderName: ThreadFolderName,
    pagination: PaginationArg | undefined,
  ) => Promise<string>

  getMessages: (
    threadID: ThreadID,
    pagination: PaginationArg | undefined,
  ) => Promise<string>

  getThread: (threadID: ThreadID) => Promise<string>

  getMessage: (threadID: ThreadID, messageID: MessageID) => Promise<string>

  createThread: (userIDs: UserID[], title: string | undefined, messageText: string | undefined) => Promise<string>

  updateThread: (threadID: ThreadID, muted: boolean) => Promise<void>

  sendMessage: (
    threadID: ThreadID,
    text?: string,
    filePath?: string,
    quotedMessageID?: string,
  ) => Promise<string>

  sendFileFromBuffer: (
    threadID: ThreadID,
    fileBuffer: Buffer,
    fileName?: string,
    quotedMessageID?: string,
  ) => Promise<string>

  editMessage: (threadID: ThreadID, messageID: MessageID, content: string | undefined) => Promise<void>

  deleteMessage: (threadID: ThreadID, messageID: MessageID) => Promise<void>

  sendReadReceipt: (threadID: ThreadID) => Promise<void>

  setReaction: (threadID: ThreadID, messageID: MessageID, reaction: string, on: boolean) => Promise<void>

  markAsUnread: (threadID: ThreadID) => Promise<void>

  onThreadSelected: (threadID: ThreadID, onEvent: OnServerEventCallback) => Promise<void>

  getAsset: (pathHex: string, methodName: string | undefined) => Promise<string | Buffer>

  deleteThread: NativeVoidPlatformAPIMethod<'deleteThread'>
  sendActivityIndicator: NativeVoidPlatformAPIMethod<'sendActivityIndicator'>
  addReaction: NativeVoidPlatformAPIMethod<'addReaction'>
  removeReaction: NativeVoidPlatformAPIMethod<'removeReaction'>
  notifyAnyway: NativeVoidPlatformAPIMethod<'notifyAnyway'>
  dispose: NativeVoidPlatformAPIMethod<'dispose'>
}

export type NativeMacPermissions = {
  getAuthStatus: (authType: NativeMacPermissionAuthType) => NativeMacPermissionAuthStatus
  askForAccessibilityAccess: () => void
  askForContactsAccess: () => Promise<NativeMacPermissionAuthStatus>
  askForFullDiskAccess: () => void
}

type IMessage = {
  isLoggingEnabled: boolean
  isPHTEnabled: boolean
  enabledExperiments: string
  useSecondaryMessagesInstance: boolean
  isMessagesAppInDock: string
  isNotificationsEnabledForMessages: boolean

  PlatformAPI: typeof NativePlatformAPI
  MacPermissions: NativeMacPermissions

  canAccessMessagesDir: () => Promise<boolean>
  validateDatabaseAccess: () => Promise<void>
  askForMessagesDirAccess: () => Promise<void>
  askForAutomationAccess: () => Promise<void>

  SystemSettingsOnboarding: {
    start: () => void
    stop: () => void
  }

  confirmUNCPrompt: () => Promise<void>
  disableMessagesNotifications: () => Promise<void>

  removeMessagesFromDock: () => void
  killDock: () => void

  setEventCallback: (cb: OnServerEventCallback) => void
  startPollingFromCurrentState: () => Promise<void>

  revealSettings: () => void

}

const imessageBinaryPath = path.join(ARCH_BINARIES_DIR_PATH, 'IMessage.node')

const require = nodeModule.createRequire(import.meta.url)
// eslint-disable-next-line import/no-dynamic-require -- can't bundle .node files
const imessage: IMessage = require(imessageBinaryPath)

export default imessage
