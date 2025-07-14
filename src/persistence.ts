import * as fs from 'node:fs/promises'
import { Thread, ThreadReminder } from '@textshq/platform-sdk'
import { AppleDate } from './time'

/** All persisted thread data. Stays in memory and gets (de)serialized from/to disk. */
export type PersistedData = Record<Thread['id'], PersistedThreadProps>

export interface ThreadArchivalState {
  /**
   * When the thread was last archived.
   *
   * This is set to the latest message's {@linkcode AppleDate}, at the time of
   * archive.
   */
  archivedAt: AppleDate
}

export interface PersistedThreadProps {
  // TODO: Add archive.
  reminder?: ThreadReminder
  archive?: ThreadArchivalState
}

export type PersistedBatchGetResults<P extends keyof PersistedThreadProps> = Record<string, PersistedThreadProps[P] | undefined>

export class Persistence {
  private data: PersistedData

  constructor(
    /** A callback used to persist the in-memory data to disk given a serialized string representation of all data. */
    private saver: (newContent: string) => Promise<void>,
    /** Any preexisting persisted data to be used in place of default values. */
    existingData?: PersistedData,
  ) {
    this.data = existingData ?? {}
  }

  private async trySaving() {
    try {
      await this.saver(JSON.stringify(this.data))
    } catch (error) {
      texts.error(`imsg: couldn't save persisted data, any changes will be lost! ${error}`)
    }
  }

  /**
   * Returns some kind of data associated with a thread.
   *
   * **Use a hashed thread ID.**
   */
  getThreadProp<P extends keyof PersistedThreadProps>(threadID: string, propName: P): PersistedThreadProps[P] | undefined {
    const value = this.data[threadID]?.[propName]
    // if (texts.IS_DEV && !value) {
    //   texts.error(`imsg: tried to read unset persisted prop "${propName}" for ${threadID}`)
    // }
    return value
  }

  /**
   * Returns data associated with multiple threads.
   *
   * **Use hashed thread IDs.**
   */
  batchGetThreadProp<P extends keyof PersistedThreadProps>(threadIDs: string[], propName: P): PersistedBatchGetResults<P> {
    const results: PersistedBatchGetResults<P> = {}
    for (const threadID of threadIDs) {
      results[threadID] = this.getThreadProp(threadID, propName)
    }
    if (texts.IS_DEV) {
      texts.log(`imsg: batch request for "${propName}" across thread ids ${JSON.stringify(threadIDs)} returned ${JSON.stringify(results, undefined, 2)}`)
    }
    return results
  }

  /**
   * Deletes any data associated with a thread.
   *
   * **Use a hashed thread ID.**
   */
  async deleteThreadProp<P extends keyof PersistedThreadProps>(threadID: string, propName: P): Promise<void> {
    if (texts.IS_DEV) {
      texts.log(`imsg: deleting persisted prop "${propName}" for ${threadID}`)
    }

    if (this.data[threadID]) {
      delete this.data[threadID][propName]

      if (Object.keys(this.data[threadID]).length === 0) {
        texts.log(`imsg: evicting ${threadID} from persisted prop data, no more keys`)
        delete this.data[threadID]
      }
    }

    await this.trySaving()
  }

  /**
   * Persists some kind of data for a thread.
   *
   * **Use a hashed thread ID.** The data value is replaced entirely; that is, no merging occurs.
   */
  async setThreadProp<P extends keyof PersistedThreadProps>(threadID: string, propName: P, propValue: PersistedThreadProps[P]): Promise<void> {
    if (texts.IS_DEV) {
      texts.log(`imsg: setting persisted prop "${propName}" for ${threadID}: ${JSON.stringify(propValue, undefined, 2)}`)
    }
    this.data[threadID] ??= {}
    this.data[threadID][propName] = propValue

    await this.trySaving()
  }
}

export async function makeJSONPersistence(saveFilePath: string): Promise<Persistence> {
  async function saver(newContent: string) {
    await fs.writeFile(saveFilePath, newContent)
  }

  try {
    const json = await fs.readFile(saveFilePath, 'utf-8')

    let parsed: unknown
    try {
      parsed = JSON.parse(json)
    } catch (error) {
      texts.error("imsg: couldn't create persistence from existing json file, going to overwrite:", String(error))
    }

    // TODO: validate `parsed` so we aren't blindly passing untrusted data to
    // the app

    return new Persistence(saver, parsed as PersistedData)
  } catch (error) {
    // If we can't read an existing file or otherwise parse existing persistent
    // data, then start fresh.
    return new Persistence(saver)
  }
}
