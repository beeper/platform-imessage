import path from 'path'
import type { OnServerEventCallback } from '@textshq/platform-sdk'

import { ARCH_BINARIES_DIR_PATH } from '../../constants'

declare const __non_webpack_require__: NodeRequire
const actualRequire = typeof __non_webpack_require__ === 'undefined' ? require : __non_webpack_require__

const {
  newServer,
  dropServer,

  startPoller,
  stopPoller,
} = actualRequire(path.join(ARCH_BINARIES_DIR_PATH, 'rust-server.node'))

export class Server {
  #client: object | null = null

  constructor(fn: OnServerEventCallback) {
    this.#client = newServer(fn)
  }

  public startPoller(last_row_id: number, last_date_read: number) {
    if (this.#client !== null) {
      this.#client = startPoller.call(this.#client, last_row_id, last_date_read)
    }

    return this.#client !== null
  }

  public stopPoller() {
    if (this.#client !== null) {
      this.#client = stopPoller.call(this.#client)
    }

    return this.#client !== null
  }

  public destroy() {
    if (this.#client !== null) {
      dropServer.call(this.#client)
    }

    this.#client = null
  }
}
