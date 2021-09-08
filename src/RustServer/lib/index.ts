import path from 'path'
import type { OnServerEventCallback } from '@textshq/platform-sdk'

import { BINARIES_DIR_PATH } from '../../constants'

declare const __non_webpack_require__: NodeRequire
const actualRequire = typeof __non_webpack_require__ === 'undefined' ? require : __non_webpack_require__

const {
  newServer,
  dropServer,

  startPoller,
  stopPoller,
} = actualRequire(path.join(BINARIES_DIR_PATH, `rs_${process.arch}.node`))

export class Server {
  #client: object

  constructor(fn: OnServerEventCallback) {
    this.#client = newServer(fn)
  }

  public startPoller(last_row_id: number, last_date_read: number) {
    this.#client = startPoller.call(this.#client, last_row_id, last_date_read)
  }

  public stopPoller() {
    this.#client = stopPoller.call(this.#client)
  }

  public destroy() {
    dropServer.call(this.#client)
    this.#client = null
  }
}
