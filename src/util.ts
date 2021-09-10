import os from 'os'

const DATE_OFFSET = 978307200000

// const appleTimeNow = () => Date.now() - DATE_OFFSET

const nanoToMs = (ts: number) => Math.floor(ts / 1e6)

export const unpackTime = (ts: number) => {
  if (!ts) return
  const nano = nanoToMs(ts)
  return nano !== 0 ? nano : ts
}

export function fromAppleTime(_ts: number) {
  if (!_ts) return
  const unpacked = nanoToMs(_ts)
  const ts = unpacked !== 0 ? unpacked : _ts
  return new Date(ts + DATE_OFFSET)
}

const HOMEDIR = os.homedir()
export function replaceTilde(str: string) {
  if (str?.[0] === '~') return HOMEDIR + str.slice(1)
  return str
}

export const getDataURI = (buffer: Buffer, mimeType = '') =>
  `data:${mimeType};base64,${buffer.toString('base64')}`

export const stringifyWithArrayBuffers = <T>(obj: T, space?: string | number) =>
  JSON.stringify(
    obj,
    (key: string, value: any) =>
      (value?.buffer instanceof ArrayBuffer ? getDataURI(Buffer.from(value)) : value),
    space,
  )

export function parseTweetURL(url: string) {
  const [, username, tweetID] = /https:\/\/twitter\.com\/(.+?)\/status\/(\d+)/.exec(url) || []
  if (tweetID) return { username, tweetID }
}
