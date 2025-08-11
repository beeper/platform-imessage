import { setTimeout as setTimeoutAsync } from 'node:timers/promises'

export interface PhaserOptions {
  delayMsAfterWaiting?: number
}

// used to serialize asynchronous operations
export default class Phaser<K extends string = string> {
  private store = new Map<K, Promise<unknown>[]>()

  constructor(private readonly options: PhaserOptions = {}) {
  }

  private add(key: K, promise: Promise<unknown>) {
    if (!this.store.has(key)) {
      this.store.set(key, [])
    }

    this.store.get(key)!.push(promise)
  }

  private removeSingle(key: K) {
    if (!this.store.has(key)) {
      return
    }

    this.store.get(key)!.shift()
  }

  /**
   * Adds some asynchronous operation, guaranteeing eventual removal.
   */
  public async bracketed<T>(key: K, pending: Promise<T>): Promise<T> {
    texts.log(`imsg/phaser/${key}: beginning bracketed operation`)
    this.add(key, pending)
    try {
      // eslint-disable-next-line @typescript-eslint/return-await -- for more explicit stacks
      return await pending
    } finally {
      texts.log(`imsg/phaser/${key}: bracketed operation completed, removing`)
      this.removeSingle(key)
    }
  }

  // important: the fulfillment of any given promise returned by this method
  // isn't further delayed by adding more promises while waiting for the `wait`
  // promise to resolve -- that is, calling `wait` only ever waits on the
  // promises that were `add`ed before the call
  public async waitForAnyCurrentlyPending(key: K): Promise<void> {
    const pending = this.store.get(key)
    if (!pending || pending.length === 0) {
      texts.log(`imsg/phaser/${key}: nothing pending`)
      return
    }

    texts.log(`imsg/phaser/${key}: ${pending.length} promise(s) pending, awaiting them`)
    await Promise.all(pending)

    if (this.options.delayMsAfterWaiting && this.options.delayMsAfterWaiting > 0) {
      await setTimeoutAsync(this.options.delayMsAfterWaiting)
    }
    texts.log(`imsg/phaser/${key}: done, proceeding`)
  }
}
