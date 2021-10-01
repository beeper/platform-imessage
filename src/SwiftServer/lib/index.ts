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

export type SwiftServer = {
  decodeAttributedString: (data: Buffer) => (Fragment[] | undefined)
  createThread: (addresses: string[], message: string) => Promise<void>
  markRead: (guid: string) => Promise<void>
  sendTypingStatus: (isTyping: boolean, address: string) => Promise<void>
  watchThreadActivity: (
    address: string | null,
    onTyping?: (status: ActivityStatus) => void
  ) => Promise<void>
  setReaction: (guid: string, offset: number, reaction: string, on: boolean) => Promise<void>
  sendTextMessage: (text: string, threadID: string) => Promise<void>
  dispose: () => void
  init: (isLoggingEnabled?: boolean) => Promise<void>
}

const swiftServerPath = path.join(BINARIES_DIR_PATH, `swift_${process.arch}.node`)

let _swiftServer: SwiftServer | undefined
if (IS_SWIFT_STABLE) {
  _swiftServer = actualRequire(swiftServerPath)
}

const swiftServer = _swiftServer
export default swiftServer
