import path from 'path'
import childProcess from 'child_process'
import { texts } from '@textshq/platform-sdk'

import { BINARIES_DIR_PATH } from './constants'

// const serverPath = path.join(texts.constants.BUILD_DIR_PATH + `/../../packages/platform-imessage/src/RustServer/target/Release/rust_server_${process.arch}_macos`)
const serverPath = path.join(BINARIES_DIR_PATH, `rust_server_${process.arch}_macos`)

function spawnRustServer(onMessage: (data: any) => void) {
  const spawn = () => childProcess.spawn(serverPath)
  let cp = spawn()
  const onStdOutData = (data: Buffer) => {
    const str = data.toString()
    if (texts.IS_DEV) console.log('RustServer:', str)
    if (str[0] === '{') {
      const json = JSON.parse(str)
      onMessage(json)
    }
  }
  const onError = (err: Error) => {
    console.error('RustServer -> stream error', err)
  }
  cp.stdout.on('data', onStdOutData)
  cp.stdout.on('error', onError)
  cp.stderr.on('error', onError)
  cp.on('error', error => {
    texts.Sentry.captureException(error)
    console.error('RustServer -> error', error)
  })
  cp.on('exit', (code) => {
    console.error('RustServer -> exit', { code })
  })
  const send = (input: any) => {
    if (cp.stdin.destroyed) cp = spawn()
    cp.stdin.write(JSON.stringify(input) + '\n')
  }
  const exit = () => cp.kill()
  return {
    send,
    exit,
  }
}

export default spawnRustServer
