import os from 'os'
import fs from 'fs/promises'
import childProcess from 'child_process'
import { setTimeout as setTimeoutAsync } from 'timers/promises'

const HOMEDIR = os.homedir()
export function replaceTilde(str: string): string
export function replaceTilde(str: undefined): undefined
export function replaceTilde(str: string | undefined): string | undefined
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
