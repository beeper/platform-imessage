import path from 'path'
import childProcess from 'child_process'
import { debounce } from 'lodash'
import { texts } from '@textshq/platform-sdk'

import { BINARIES_DIR_PATH } from './constants'

// const serverPath = path.join(texts.constants.BUILD_DIR_PATH + `/../../packages/platform-imessage/src/RustServer/target/Release/rust_server_${process.arch}_macos`)
const serverPath = path.join(BINARIES_DIR_PATH, `rust_server_${process.arch}_macos`)

const LF = 10

function spawnRustServer(onMessage: (data: any) => void) {
  const spawn = () => childProcess.spawn(serverPath)
  let cp = spawn()
  let chunks: Buffer[] = []
  const onStdOutData = (chunk: Buffer) => {
    chunks.push(chunk)
    if (chunk[chunk.length - 1] === LF) {
      const str = Buffer.concat(chunks).toString()
      chunks = []
      if (texts.IS_DEV) console.log('RustServer:', str)
      const json = JSON.parse(str)
      onMessage(json)
    }
  }
  const onError = (err: Error) => {
    console.error('RustServer -> stream error', err)
  }
  cp.stdout.on('data', onStdOutData)
  let errBuffers: Buffer[] = []
  const report = debounce(() => {
    texts.Sentry.captureException('RustServer.stderr: ' + errBuffers.concat().toString())
    errBuffers = []
  }, 5_000)
  cp.stderr.on('data', (data: Buffer) => {
    errBuffers.push(data)
    process.stdout.write(data)
    report()
  })
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
