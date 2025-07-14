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

  private needsSaving = false

  constructor(
    /** A callback used to persist the in-memory data to disk given a serialized string representation of all data. */
    private saver: (newContent: string) => Promise<void>,
    /** Any preexisting persisted data to be used in place of default values. */
    existingData?: PersistedData,
  ) {
    this.data = existingData ?? {}
  }

  private invalidateSavedData() {
    if (this.needsSaving) return
    this.needsSaving = true;

    (async () => {
      if (texts.IS_DEV) {
        texts.log('imsg: persistence is going to save data')
      }
      if (!this.needsSaving) {
        // we don't expect concurrent instances of this microtask due to the
        // boolean, but check this anyways in order to prevent corruption
        texts.error('imsg: `needsSaving` became false somehow, something very sneaky is going on')
        return
      }

      try {
        await this.saver(JSON.stringify(this.data))
      } catch (error) {
        texts.error(`imsg: couldn't persist data, any changes will be lost: ${String(error)}`)
      }
      this.needsSaving = false
    })()
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
  deleteThreadProp<P extends keyof PersistedThreadProps>(threadID: string, propName: P): void {
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

    this.invalidateSavedData()
  }

  /**
   * Persists some kind of data for a thread.
   *
   * **Use a hashed thread ID.** The data value is replaced entirely; that is, no merging occurs.
   */
  setThreadProp<P extends keyof PersistedThreadProps>(threadID: string, propName: P, propValue: PersistedThreadProps[P]): void {
    if (texts.IS_DEV) {
      texts.log(`imsg: setting persisted prop "${propName}" for ${threadID}: ${JSON.stringify(propValue, undefined, 2)}`)
    }
    this.data[threadID] ??= {}
    this.data[threadID][propName] = propValue

    this.invalidateSavedData()
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
