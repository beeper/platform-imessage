import { spawn } from 'child_process'
import { EventEmitter } from 'events'
import { texts } from '@textshq/platform-sdk'

const serverPath = texts.constants.BUILD_DIR_PATH + '/AppleScriptServer'

function spawnASServer() {
  const cp = spawn(serverPath, ['embedded-json'])
  const ev = new EventEmitter()
  const onData = (data: Buffer) => {
    const str = data.toString()
    if (texts.IS_DEV) console.log('AppleScriptServer:', str)
    if (str[0] === '{') {
      const json = JSON.parse(str)
      ev.emit(json.tag, json)
    }
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
  const run = <T>(scriptName: string, args: string[] = []) => (
    new Promise<T>((resolve, reject) => {
      const tag = Date.now().toString(36) + Math.random().toString(36)
      const input = { tag, scriptName, args }
      ev.once(tag, json => {
        if (json.error) reject(new Error(json.error))
        else resolve(json.output)
      })
      cp.stdin.write(JSON.stringify(input) + '\n')
    })
  )
  const exit = () => cp.kill()
  return { run, exit }
}

export default spawnASServer
