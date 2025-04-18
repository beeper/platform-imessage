import path from 'node:path'
import nodeModule from 'node:module'
import type { OnServerEventCallback } from '@textshq/platform-sdk'

import { ARCH_BINARIES_DIR_PATH } from '../../constants'

const require = nodeModule.createRequire(import.meta.url)
// eslint-disable-next-line import/no-dynamic-require -- can't bundle .node files
const RustServer = require(path.join(ARCH_BINARIES_DIR_PATH, 'rust-server.node'))
const { PollerServer } = RustServer

export type HasherToken = string

export interface IHasher {
  /** throws if not found */
  originalFromHash(token: HasherToken): string

  hashAndRemember(pii: string): HasherToken
}

export interface IServer {
  startPoller(lastRowID: bigint, lastDateRead: bigint): void

  stopPoller(): void
}

export const Server: { new(callback: OnServerEventCallback): IServer } = PollerServer

export const threadHasher: IHasher = {
  originalFromHash(token) { return RustServer.originalThreadId(token) },
  hashAndRemember(pii) { return RustServer.hashThreadId(pii) },
}

export const participantHasher: IHasher = {
  originalFromHash(token) { return RustServer.originalParticipantId(token) },
  hashAndRemember(pii) { return RustServer.hashParticipantId(pii) },
}
