import fs from 'fs/promises'
import { setTimeout as setTimeoutAsync } from 'node:timers/promises'

export { shellExec } from './shell-exec'

export const getDataURI = (buffer: Buffer, mimeType = '') =>
  `data:${mimeType};base64,${buffer.toString('base64')}`

export const stringifyWithArrayBuffers = <T>(obj: T, space?: string | number) =>
  JSON.stringify(
    obj,
    function (key: string, value: any) {
      if (value === null || typeof value !== 'object') return value
      const originalValue = this[key]
      if (ArrayBuffer.isView(originalValue)) {
        return getDataURI(Buffer.from(
          originalValue.buffer,
          originalValue.byteOffset,
          originalValue.byteLength,
        ))
      }
      return value
    },
    space,
  )

export function parseTweetURL(url: string) {
  const [,, username, tweetID] = /https?:\/\/(?:[a-z]+\.)?(twitter|x)\.com\/(.+?)\/status\/(\d+)/.exec(url) || []
  if (tweetID) return { username, tweetID }
}

export const pathExists = (fp: string) =>
  fs.access(fp)
    .then(() => true)
    .catch(() => false)

export async function waitForFileToExist(filePath: string, maxWaitMs: number) {
  const stopAt = Date.now() + maxWaitMs
  while (!await pathExists(filePath)) {
    if (Date.now() > stopAt) return false
    await setTimeoutAsync(20)
  }
  return true
}

export const threadIDToAddress = (threadID: string): string =>
  threadID.split(';', 3).pop() as string // .split() never returns an empty array

const singleParticipantChatGuid = /^(RCS|iMessage|any);-;/
export function getSingleParticipantAddress(threadID: string | null): string | null {
  if (!threadID || !singleParticipantChatGuid.test(threadID)) return null
  return threadIDToAddress(threadID)
}
