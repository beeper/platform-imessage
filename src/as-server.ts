import crypto from 'crypto'
import path from 'path'
import childProcess from 'child_process'
import { EventEmitter } from 'events'
import { texts } from '@textshq/platform-sdk'
import { ARCH_BINARIES_DIR_PATH } from './constants'
import IS_DEV_ENVIRON from './is-dev-environ'

const serverPath = path.join(ARCH_BINARIES_DIR_PATH, 'AppleScriptServer')

function spawnASServer() {
  const spawn = () => childProcess.spawn(serverPath, ['embedded-json'])
  let cp = spawn()
  const ev = new EventEmitter()
  const onData = (data: Buffer) => {
    const items = data.toString().split('\n')
    if (texts.IS_DEV) console.log('AppleScriptServer:', items)
    items.forEach(item => {
      if (!item) return
      if (item[0] !== '{') return console.error('AppleScriptServer: unknown', item)
      const json = JSON.parse(item)
      ev.emit(json.tag, json)
    })
  }
  const onError = (err: Error) => {
    console.error('AppleScriptServer -> stream error', err)
  }
  cp.stdout.on('data', onData)
  cp.stderr.on('data', onData)
  cp.stdout.on('error', onError)
  cp.stderr.on('error', onError)
  cp.on('error', error => {
    texts.Sentry.captureException(error)
    console.error('AppleScriptServer -> error', error)
  })
  cp.on('exit', code => {
    console.error('AppleScriptServer -> exit', { code })
  })
  const run = <T>(scriptName: string, args: string[] = []) => (
    new Promise<T>((resolve, reject) => {
      const startTime = IS_DEV_ENVIRON ? Date.now() : undefined
      if (IS_DEV_ENVIRON) console.log('[imsg.as2] ↑', scriptName, args)
      const tag = crypto.randomUUID()
      const input = { tag, scriptName, args }
      const timeout = setTimeout(() => {
        reject(Error('as2 timed out'))
      }, 10_000) // should resolve in <100 ms so 10s is a lot
      ev.once(tag, json => {
        clearTimeout(timeout)
        if (IS_DEV_ENVIRON && startTime) console.log('[imsg.as2] ↓', scriptName, json, Date.now() - startTime, 'ms')
        if (json.error) reject(new Error(json.error))
        else resolve(json.output)
      })
      if (cp.stdin.destroyed) cp = spawn()
      cp.stdin.write(JSON.stringify(input) + '\n')
    })
  )
  const exit = () => cp.kill()
  return { run, exit }
}

export default spawnASServer
