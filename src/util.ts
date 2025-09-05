import os from 'os'
import fs from 'fs/promises'
import * as stream from 'stream'
import childProcess from 'child_process'
import * as rl from 'readline/promises'
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

async function* concatStreams<T>(readables: stream.Readable[]): AsyncIterable<T> {
  for (const readable of readables) {
    for await (const chunk of readable) {
      yield chunk
    }
  }
}

export async function shellExec(command: string, ...args: readonly string[]): Promise<string> {
  const cp = childProcess.spawn(command, args)
  const lineInterface = rl.createInterface({
    input: stream.Readable.from(concatStreams([cp.stdout, cp.stderr])),
    crlfDelay: Infinity,
  })
  const lines: string[] = [];
  (async () => {
    for await (const line of lineInterface) {
      console.log(`\x1b[1m${command}\x1b[0m: ${line}`)
      lines.push(line)
    }
  })()
  return new Promise<string>((resolve, reject) => {
    cp.on('exit', code => {
      if (code) {
        reject(new Error(`${command} exited with status code ${code}`))
      } else {
        resolve(lines.join('\n'))
      }
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

const singleParticipantChatGuid = /^(RCS|iMessage|any);-;/
export function getSingleParticipantAddress(threadID: string | null): string | null {
  if (!threadID || !singleParticipantChatGuid.test(threadID)) return null
  return threadIDToAddress(threadID)
}
