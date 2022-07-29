import path from 'path'
import type { OnServerEventCallback } from '@textshq/platform-sdk'

import { ARCH_BINARIES_DIR_PATH } from '../../constants'

declare const __non_webpack_require__: NodeRequire
const actualRequire = typeof __non_webpack_require__ === 'undefined' ? require : __non_webpack_require__

const { PollerServer } = actualRequire(path.join(ARCH_BINARIES_DIR_PATH, 'rust-server.node'))

export interface IServer {
  startPoller(lastRowID: bigint, lastDateRead: bigint): void

  stopPoller(): void
}

export const Server: { new(callback: OnServerEventCallback): IServer } = PollerServer
