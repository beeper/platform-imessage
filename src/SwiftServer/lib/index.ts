import path from 'path'

import { BINARIES_DIR_PATH, IS_SWIFT_STABLE } from '../../constants'

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
  messagesControllerClass: typeof MessagesController
}

const swiftServerPath = path.join(BINARIES_DIR_PATH, `${process.platform}-${process.arch}`, 'swift-server.node')

let _swiftServer: SwiftServer | undefined
if (IS_SWIFT_STABLE) {
  _swiftServer = actualRequire(swiftServerPath)
  _swiftServer.messagesControllerClass = (_swiftServer as any).MessagesController
}

const swiftServer = _swiftServer
export default swiftServer
