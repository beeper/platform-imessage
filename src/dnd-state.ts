import { promises as fs } from 'fs'
import { DISTANT_FUTURE_CONSTANT, DND_PLIST_PATH } from './constants'
import safeBplistParse from './safe-bplist-parse'

const set = new Set<string>()
let lastModifiedMs: number
export default async function getDNDState() {
  if (!DND_PLIST_PATH) return set
  try {
    const stat = await fs.lstat(DND_PLIST_PATH)
    // if not modified don't read again
    if (lastModifiedMs === stat.mtimeMs) return set
    lastModifiedMs = stat.mtimeMs
  } catch (err) {
    console.error(err)
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
}
