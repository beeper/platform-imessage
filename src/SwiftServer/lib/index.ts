import path from 'node:path'
import nodeModule from 'node:module'
import type { OnServerEventCallback, Size, ThreadID } from '@textshq/platform-sdk'

import { ARCH_BINARIES_DIR_PATH } from '../../constants'

export const enum ActivityStatus {
  DND = 'DND',
  DNDCanNotify = 'DND_CAN_NOTIFY',
  Typing = 'TYPING',
  NotTyping = 'NOT_TYPING',
  Unknown = 'UNKNOWN',
}

export declare class MessagesController {
  isValid: () => Promise<boolean>

  createThread: (addresses: string[], messageText: string) => Promise<void>

  toggleThreadRead: (threadID: ThreadID, read: boolean) => Promise<void>

  muteThread: (threadID: ThreadID, muted: boolean) => Promise<void>

  deleteThread: (threadID: ThreadID) => Promise<void>

  undoSend: (threadID: ThreadID, messageID: string) => Promise<void>

  editMessage: (threadID: ThreadID, messageID: string, newText: string) => Promise<void>

  notifyAnyway: (threadID: ThreadID) => Promise<void>

  sendTypingStatus: (threadID: ThreadID, isTyping: boolean) => Promise<void>

  watchThreadActivity: (threadID?: ThreadID, onTyping?: (status: ActivityStatus[]) => void) => Promise<void>

  sendMessage: (
    threadID: ThreadID,
    text?: string,
    filePath?: string,
    quotedMessageID?: string,
  ) => Promise<void>

  setReaction: (threadID: ThreadID, messageID: string, reaction: string, on: boolean) => Promise<void>

  isSameContact: (addressA: string, addressB: string) => boolean
}

export declare class SwiftPlatformAPI {
  constructor(accountID: string)

  getMessagesController: (forceInvalidate?: boolean) => Promise<MessagesController>

  getCurrentUser: () => Promise<string>

  getMessages: (threadID: string, cursor: string | undefined, direction: 'after' | 'before' | undefined, limit?: number) => Promise<string>

  getMessage: (threadID: string, messageID: string) => Promise<string>

  getThreads: (folderName: string, cursor: string | undefined, direction: 'after' | 'before' | undefined) => Promise<string>

  getThread: (threadID: string) => Promise<string>

  searchMessages: (query: string, threadID: string | undefined, mediaOnly: boolean | undefined, sender: string | undefined, limit?: number) => Promise<string>

  onThreadSelected: (threadID: ThreadID, onEvent: OnServerEventCallback, messagesController: MessagesController) => Promise<void>

  notifyAnyway: (threadID: ThreadID) => Promise<void>

  sendReadReceipt: (threadID: ThreadID) => Promise<void>

  getAttachmentFilePath: (messageRowID: number) => Promise<string | undefined>

  getChatImageFilePath: (attachmentGUID: string) => Promise<string | undefined>

  dispose: () => void
}

// purely for headless (REPL) tab-autocomplete
export const MESSAGES_CONTROLLER_METHOD_NAMES = [
  'isValid',
  'createThread',
  'toggleThreadRead',
  'muteThread',
  'deleteThread',
  'undoSend',
  'editMessage',
  'notifyAnyway',
  'sendTypingStatus',
  'watchThreadActivity',
  'sendMessage',
  'setReaction',
  'isSameContact',
] as const satisfies (keyof MessagesController)[]

export type SwiftServer = {
  appleInterfaceStyle: string
  isLoggingEnabled: boolean
  isPHTEnabled: boolean
  enabledExperiments: string
  isMessagesAppInDock: string
  isNotificationsEnabledForMessages: boolean

  PlatformAPI: typeof SwiftPlatformAPI

  mapMessageJSON: (inputJSON: string) => string
  getImageMetadata: (filePath: string) => Promise<Size | undefined>
  resolveThreadID: (threadID: ThreadID) => Promise<ThreadID>
  hashParticipantID: (id: string) => string
  askForMessagesDirAccess: () => Promise<void>
  askForAutomationAccess: () => Promise<void>

  startSysPrefsOnboarding?: () => Promise<void>
  stopSysPrefsOnboarding?: () => void

  confirmUNCPrompt: () => Promise<void>
  disableNotificationsForApp: (appName: string) => Promise<void>

  removeMessagesFromDock: () => void
  killDock: () => void

  disableSoundEffects: () => void

  cancelPollingIfNecessary: () => void
  startPolling: (cb: OnServerEventCallback, lastRowID: bigint, lastDateReadNanoseconds: bigint) => void

  revealSettings: () => void

}

const swiftServerPath = path.join(ARCH_BINARIES_DIR_PATH, 'SwiftServer.node')

const nodeRequire = nodeModule.createRequire(path.join(process.cwd(), 'SwiftServer.node-loader.js'))
// eslint-disable-next-line import/no-dynamic-require -- can't bundle .node files
const swiftServer: SwiftServer = nodeRequire(swiftServerPath)

export default swiftServer
