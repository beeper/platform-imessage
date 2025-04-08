import os from 'os'
import fs from 'fs/promises'
import childProcess from 'child_process'
import { setTimeout as setTimeoutAsync } from 'timers/promises'

const DATE_OFFSET = 978307200000

// const appleTimeNow = () => Date.now() - DATE_OFFSET

const nanoToMs = (ts: number) => Math.floor(ts / 1e6)

export const unpackTime = (ts: number) => {
  if (!ts) return
  const nano = nanoToMs(ts)
  return nano !== 0 ? nano : ts
}

export function fromAppleTime(timestampText: string): Date | undefined {
  if (
    !timestampText
      // Apple frequently uses a date value of 0 to represent no value. When we
      // cast these to text, they become truthy (in JS's eyes), so be sure to
      // check for that.
      || timestampText === '0'
  ) return
  const milliseconds = BigInt(timestampText) / 1_000_000n
  // fall back to apple's epoch
  if (milliseconds === 0n) return new Date(DATE_OFFSET)
  // assume that milliseconds can fit into safe integer representations now
  return new Date(Number(milliseconds) + DATE_OFFSET)
}

const HOMEDIR = os.homedir()
export function replaceTilde(str?: string) {
  if (str?.[0] === '~') return HOMEDIR + str.slice(1)
  return str
}

export const getDataURI = (buffer: Buffer, mimeType = '') =>
  `data:${mimeType};base64,${buffer.toString('base64')}`

export const stringifyWithArrayBuffers = <T>(obj: T, space?: string | number) =>
  JSON.stringify(
    obj,
    (_key: string, value: any) =>
      (value?.buffer instanceof ArrayBuffer ? getDataURI(Buffer.from(value)) : value),
    space,
  )

export function parseTweetURL(url: string) {
  const [,, username, tweetID] = /https?:\/\/(?:[a-z]+\.)?(twitter|x)\.com\/(.+?)\/status\/(\d+)/.exec(url) || []
  if (tweetID) return { username, tweetID }
}

export async function shellExec(command: string, ...args: readonly string[]): Promise<string> {
  const cp = childProcess.spawn(command, args)
  const chunks: Uint8Array[] = []
  cp.stdout.on('data', chunk => {
    if (!(chunk instanceof Uint8Array || chunk instanceof Buffer)) throw new Error('shellExec received unexpected type of data')
    chunks.push(chunk)
  })
  return new Promise<string>(resolve => {
    cp.stdout.on('end', () => {
      resolve(Buffer.concat(chunks).toString())
    })
  })
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

export function getSingleParticipantAddress(threadID: string | null): string | null {
  if (!threadID?.startsWith('iMessage;-;')) return null
  return threadIDToAddress(threadID)
}
