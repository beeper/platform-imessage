import path from 'node:path'
import nodeModule from 'node:module'
import type { OnServerEventCallback, ThreadID } from '@textshq/platform-sdk'

import { ARCH_BINARIES_DIR_PATH } from '../../constants'

export declare class SwiftPlatformAPI {
  constructor(accountID: string)

  createThread: (addresses: string[], title: string | undefined, message: string | undefined) => Promise<string>

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

  setReaction: (threadID: ThreadID, messageID: string, reaction: string, on: boolean) => Promise<void>

  getCurrentUser: () => Promise<string>

  getMessages: (threadID: string, cursor: string | undefined, direction: 'after' | 'before' | undefined, limit?: number) => Promise<string>

  getMessage: (threadID: string, messageID: string) => Promise<string>

  getThreads: (folderName: string, cursor: string | undefined, direction: 'after' | 'before' | undefined) => Promise<string>

  getThread: (threadID: string) => Promise<string>

  searchMessages: (query: string, threadID: string | undefined, mediaOnly: boolean | undefined, sender: string | undefined, limit?: number) => Promise<string>

  onThreadSelected: (threadID: ThreadID, onEvent: OnServerEventCallback) => Promise<void>

  notifyAnyway: (threadID: ThreadID) => Promise<void>

  deleteMessage: (threadID: ThreadID, messageID: string) => Promise<void>

  editMessage: (threadID: ThreadID, messageID: string, newText: string | undefined) => Promise<void>

  deleteThread: (threadID: ThreadID) => Promise<void>

  updateThread: (threadID: ThreadID, muted: boolean) => Promise<void>

  sendActivityIndicator: (type: string, threadID: ThreadID | undefined, sendingMessagesCount?: number) => Promise<void>

  markAsUnread: (threadID: ThreadID) => Promise<void>

  sendReadReceipt: (threadID: ThreadID) => Promise<void>

  getAsset: (pathHex: string, methodName: string | undefined) => Promise<string | Buffer>

  dispose: () => Promise<void>
}

type SwiftServer = {
  isLoggingEnabled: boolean
  isPHTEnabled: boolean
  enabledExperiments: string
  useSecondaryMessagesInstance: boolean
  isMessagesAppInDock: string
  isNotificationsEnabledForMessages: boolean

  PlatformAPI: typeof SwiftPlatformAPI

  canAccessMessagesDir: () => Promise<boolean>
  validateDatabaseAccess: () => Promise<void>
  askForMessagesDirAccess: () => Promise<void>
  askForAutomationAccess: () => Promise<void>

  startSysPrefsOnboarding?: () => Promise<void>
  stopSysPrefsOnboarding?: () => void

  confirmUNCPrompt: () => Promise<void>
  disableMessagesNotifications: () => Promise<void>

  removeMessagesFromDock: () => void
  killDock: () => void

  setEventCallback: (cb: OnServerEventCallback) => void
  startPollingFromCurrentState: () => Promise<void>

  revealSettings: () => void

}

const swiftServerPath = path.join(ARCH_BINARIES_DIR_PATH, 'SwiftServer.node')

const nodeRequire = nodeModule.createRequire(path.join(process.cwd(), 'SwiftServer.node-loader.js'))
// eslint-disable-next-line import/no-dynamic-require -- can't bundle .node files
const swiftServer: SwiftServer = nodeRequire(swiftServerPath)

export default swiftServer
