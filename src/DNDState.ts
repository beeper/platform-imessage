import { texts } from '@textshq/platform-sdk'
import path from 'path'
import { promises as fs } from 'fs'
import { DISTANT_FUTURE_CONSTANT, homedir, IS_BIG_SUR_OR_UP } from './constants'
import safeBplistParse from './safe-bplist-parse'

const DND_PLIST_PATH = IS_BIG_SUR_OR_UP
  ? path.join(homedir, 'Library/Preferences/com.apple.MobileSMS.CKDNDList.plist')
  : undefined

export default class DNDStateManager {
  private readonly set = new Set<string>()

  private lastModifiedMs: number

  async get() {
    const { set } = this
    if (!DND_PLIST_PATH) return set
    try {
      try {
        const stat = await fs.lstat(DND_PLIST_PATH)
        // if not modified don't read again
        if (this.lastModifiedMs === stat.mtimeMs) return set
        this.lastModifiedMs = stat.mtimeMs
      } catch (err) {
        console.error(err)
        texts.Sentry.captureException(err)
        return set
      }
      const bplist = await fs.readFile(DND_PLIST_PATH)
      /*
        {
          CatalystDNDMigrationVersion: 2,
          CKDNDMigrationKey: 2,
          CKDNDListKey: {
            'hi@kishan.info': 64092211200,
            // chat.group_id
            '2B4EFF7E-3F26-4251-8902-F7062096CCCC: 64092211200,
            '+15551231234': 64092211200
          }
        }
      */
      const parsed = safeBplistParse(bplist)
      set.clear()
      if (!parsed?.CKDNDListKey) return set
      Object.entries(parsed.CKDNDListKey).forEach(([id, timestamp]) => {
        if (timestamp === DISTANT_FUTURE_CONSTANT) set.add(id)
      })
      return set
    } catch (err) {
      // if (err.code === 'EPERM') handle
      console.error(err)
      texts.Sentry.captureException(err)
      return set
    }
  }
}
