import path from 'path'
import fs from 'fs'

import { ARCH_BINARIES_DIR_PATH, IS_BIG_SUR_OR_UP } from '../../constants'

declare const __non_webpack_require__: NodeRequire
const actualRequire = typeof __non_webpack_require__ === 'undefined' ? require : __non_webpack_require__

export interface Fragment {
  from: number
  to: number
  text: string
  attributes: { [key: string]: string }
}

export enum ActivityStatus {
  Typing = 'TYPING',
  NotTyping = 'NOT_TYPING',
  Unknown = 'UNKNOWN',
}

export declare class MessagesController {
  static create(): Promise<MessagesController>

  isValid: () => Promise<boolean>

  createThread: (addresses: string[], message: string) => Promise<void>

  markRead: (guid: string) => Promise<void>

  sendTypingStatus: (isTyping: boolean, address: string) => Promise<void>

  watchThreadActivity: (
    address: string | null,
    onTyping?: (status: ActivityStatus) => void
  ) => Promise<void>

  setReaction: (guid: string, offset: number, reaction: string, on: boolean) => Promise<void>

  sendTextMessage: (text: string, threadID: string) => Promise<void>

  sendReply: (guid: string, text: string) => Promise<void>

  dispose: () => void
}

export type SwiftServer = {
  decodeAttributedString: (data: Buffer) => (Fragment[] | undefined)
  isLoggingEnabled: boolean
  isPHTEnabled: boolean
  messagesControllerClass: typeof MessagesController
  askForMessagesDirAccess: () => Promise<void>
}

const hasSwiftLibs = IS_BIG_SUR_OR_UP || fs.existsSync('/usr/lib/swift')
const swiftServerPath = path.join(ARCH_BINARIES_DIR_PATH, 'swift-server.node')

let _swiftServer: SwiftServer | undefined
if (hasSwiftLibs) {
  _swiftServer = actualRequire(swiftServerPath)
  _swiftServer.messagesControllerClass = (_swiftServer as any).MessagesController
}

const swiftServer = _swiftServer
export default swiftServer
