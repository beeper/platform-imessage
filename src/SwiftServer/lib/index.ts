import path from 'path'
import os from 'os'

import { BINARIES_DIR_PATH } from '../../constants'

declare const __non_webpack_require__: NodeRequire
const actualRequire = typeof __non_webpack_require__ === 'undefined' ? require : __non_webpack_require__

export interface Attribute {
  key: string
  value: string
  from: number
  to: number
}

export enum ActivityStatus {
  Typing = 'TYPING',
  NotTyping = 'NOT_TYPING',
  Unknown = 'UNKNOWN',
}

export type SwiftServer = {
  decodeAttributedString: (data: Buffer) => (Attribute[] | undefined)
  createThread: (addresses: string[]) => void
  markRead: (guid: string) => Promise<void>
  sendTypingStatus: (isTyping: boolean, address: string) => Promise<void>
  watchThreadActivity: (
    address: string | null,
    onTyping?: (status: ActivityStatus) => void
  ) => void
  setReaction: (guid: string, offset: number, reaction: string, on: boolean) => void
  dispose: () => void
  init: (isLoggingEnabled?: boolean) => Promise<void>
}

const swiftServerPath = path.join(BINARIES_DIR_PATH, `swift_${process.arch}.node`)

let _swiftServer: SwiftServer | undefined
// darwin >= 18.5.0 (macOS 10.14.4)
if (os.platform() === 'darwin') {
  const release = os.release().split('.')
  const major = +release[0]
  const minor = +release[1]
  if (major > 18 || (major === 18 && minor >= 5)) {
    _swiftServer = actualRequire(swiftServerPath)
  }
}

const swiftServer = _swiftServer
export default swiftServer
