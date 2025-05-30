import path from 'node:path'
import nodeModule from 'node:module'
import type { MessageID, OnServerEventCallback, ThreadID } from '@textshq/platform-sdk'

import { ARCH_BINARIES_DIR_PATH } from '../../constants'

export interface Fragment {
  from: number
  to: number
  text: string
  attributes: { [key: string]: string }
}

export const enum ActivityStatus {
  DND = 'DND',
  DNDCanNotify = 'DND_CAN_NOTIFY',
  Typing = 'TYPING',
  NotTyping = 'NOT_TYPING',
  Unknown = 'UNKNOWN',
}

export interface MessageCell {
  messageGUID: MessageID
  offset: number
  cellID: string | null
  cellRole: string | null
  overlay: boolean
}

export interface Hasher {
  tokenizeRemembering: (pii: string) => string
  /** throws if not found */
  recoverOriginal: (token: string) => string
}

export declare class MessagesController {
  static create(): Promise<MessagesController>

  isValid: () => Promise<boolean>

  createThread: (addresses: string[], messageText: string) => Promise<void>

  toggleThreadRead: (threadID: ThreadID, read: boolean) => Promise<void>

  muteThread: (threadID: ThreadID, muted: boolean) => Promise<void>

  deleteThread: (threadID: ThreadID) => Promise<void>

  undoSend: (threadID: ThreadID, messageCellJSON: string) => Promise<void>

  editMessage: (threadID: ThreadID, messageCellJSON: string, newText: string) => Promise<void>

  notifyAnyway: (threadID: ThreadID) => Promise<void>

  sendTypingStatus: (threadID: ThreadID, isTyping: boolean) => Promise<void>

  watchThreadActivity: (threadID?: ThreadID, onTyping?: (status: ActivityStatus[]) => void) => Promise<void>

  sendMessage: (threadID: ThreadID, text?: string, filePath?: string, quotedMessageCellJSON?: string) => Promise<void>

  setReaction: (threadID: ThreadID, messageCellJSON: string, reaction: string, on: boolean) => Promise<void>

  isSameContact: (addressA: string, addressB: string) => boolean

  dispose: () => void
}

export type SwiftServer = {
  appleInterfaceStyle: string
  isLoggingEnabled: boolean
  isPHTEnabled: boolean
  enabledExperiments: string
  isMessagesAppInDock: string
  isNotificationsEnabledForMessages: boolean

  decodeAttributedString: (data: Buffer) => (Fragment[] | undefined)
  messagesControllerClass: typeof MessagesController
  askForMessagesDirAccess: () => Promise<void>
  askForAutomationAccess: () => Promise<void>

  startSysPrefsOnboarding?: () => Promise<void>
  stopSysPrefsOnboarding?: () => void

  confirmUNCPrompt: () => Promise<void>
  disableNotificationsForApp: (appName: string) => Promise<void>

  removeMessagesFromDock: () => void
  killDock: () => void

  disableSoundEffects: () => void

  getDNDList: () => string[]

  cancelPollingIfNecessary: () => void
  startPolling: (cb: OnServerEventCallback, lastRowID: bigint, lastDateReadNanoseconds: bigint) => void

  hashers: {
    thread: Hasher
    participant: Hasher
  }
}

const swiftServerPath = path.join(ARCH_BINARIES_DIR_PATH, 'SwiftServer.node')

const require = nodeModule.createRequire(import.meta.url)
// eslint-disable-next-line import/no-dynamic-require -- can't bundle .node files
const swiftServer: SwiftServer = require(swiftServerPath)
swiftServer.messagesControllerClass = (swiftServer as unknown as { MessagesController: typeof MessagesController }).MessagesController

export default swiftServer
