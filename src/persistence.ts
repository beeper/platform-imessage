import * as fs from 'node:fs/promises'
import { Thread, ThreadReminder } from '@textshq/platform-sdk'
import { AppleDate } from './time'
/* eslint-disable no-void -- we are being explicit about "naked" promise calls */

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
  archive?: ThreadArchivalState
  pin?: boolean
  reminder?: ThreadReminder
}

export type PersistedBatchGetResults<P extends keyof PersistedThreadProps> = Record<string, PersistedThreadProps[P] | undefined>

export class Persistence {
  private data: PersistedData

  /** The current version number of the data. Used to prevent writes racing each other. */
  private version = 0

  private saveInFlight = false

  constructor(
    /** A callback used to persist the in-memory data to disk given a serialized string representation of all data. */
    private saver: (newContent: string) => Promise<void>,
    /** Any preexisting persisted data to be used in place of default values. */
    existingData?: PersistedData,
  ) {
    this.data = existingData ?? {}
  }

  private invalidateSavedData() {
    this.version++

    if (!this.saveInFlight) {
      // we have new changes and we aren't already in the middle of saving, so
      // enqueue a save
      this.saveInFlight = true
      void this.save(this.version)
    } else {
      // we have new changes in-memory, but we are still in the middle of
      // writing out to disk. since `actuallySave` checks for outstanding
      // writes that happened while it was busy (via
      // `version`/`lastSavedVersion`), do nothing here
    }
  }

  private async save(versionToWrite: number) {
    texts.log(`imsg/persistence: going to save data (${versionToWrite})`)

    try {
      await this.saver(JSON.stringify(this.data))
    } catch (error) {
      texts.error(`imsg/persistence: couldn't persist data (${versionToWrite}), any changes will be lost: ${String(error)}`)

      // don't do the version check, because if the write fails again we'd just
      // hammer retries infinitely -- at this point, just try writing when/if
      // the data changes next time (also, this early exit still sets
      // `saveInFlight` to `false`)
      return
    } finally {
      this.saveInFlight = false
    }

    // check if the in-memory data was invalidated while we were writing, and
    // schedule another write if so
    const versionAfterSaving = this.version
    if (versionAfterSaving > versionToWrite) {
      texts.log(`imsg/persistence: witnessed version changed to ${versionAfterSaving} (from ${versionToWrite}) after done writing, queueing another save`)
      void this.save(versionAfterSaving)
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
    texts.log(`imsg/persistence: batch request for "${propName}" across thread ids ${JSON.stringify(threadIDs)} returned: ${JSON.stringify(results, undefined, 2)}`)
    return results
  }

  /**
   * Deletes any data associated with a thread.
   *
   * **Use a hashed thread ID.**
   */
  deleteThreadProp<P extends keyof PersistedThreadProps>(threadID: string, propName: P): void {
    texts.log(`imsg/persistence: deleting persisted prop "${propName}" for ${threadID}`)

    if (this.data[threadID]) {
      delete this.data[threadID][propName]

      if (Object.keys(this.data[threadID]).length === 0) {
        texts.log(`imsg/persistence: evicting ${threadID}, no more keys`)
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
    texts.log(`imsg/persistence: setting "${propName}" for ${threadID}: ${JSON.stringify(propValue, undefined, 2)}`)
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
      texts.error("imsg/persistence: couldn't create from existing json file, going to overwrite:", String(error))
    }

    // TODO: validate `parsed` so we aren't blindly passing untrusted data to
    // the app

    return new Persistence(saver, parsed as PersistedData)
  } catch (error) {
    texts.log(`imsg/persistence: creating fresh instance: ${error}`)
    // If we can't read an existing file then start fresh.
    return new Persistence(saver)
  }
}
