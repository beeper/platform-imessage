import { spawn } from 'node:child_process'
import * as fs from 'node:fs/promises'
import * as os from 'node:os'
import * as path from 'node:path'
import { performance } from 'node:perf_hooks'
import * as readline from 'node:readline'
import { pathToFileURL } from 'node:url'

export async function timedCall(fn) {
  const startedAt = performance.now()
  try {
    return {
      ok: true,
      value: await fn(),
      ms: performance.now() - startedAt,
    }
  } catch (error) {
    return {
      ok: false,
      error,
      ms: performance.now() - startedAt,
    }
  }
}

function serializeError(error) {
  return {
    name: error instanceof Error ? error.name : undefined,
    message: error instanceof Error ? error.message : String(error),
    stack: error instanceof Error ? error.stack : undefined,
  }
}

function deserializeError(value) {
  const error = new Error(value?.message ?? String(value))
  if (value?.name) error.name = value.name
  if (value?.stack) error.stack = value.stack
  return error
}

async function createAPI({
  role,
  repoRoot,
  referenceAPIPath,
  referenceBinariesDirPath,
}) {
  const dataDirPath = await fs.mkdtemp(path.join(os.tmpdir(), `platform-imessage-parity-${role}-`))
  let APIClass
  if (role === 'reference') {
    if (!referenceAPIPath) throw new Error('reference child requires --reference-api-bundle')
    globalThis.texts.getBinariesDirPath = () => referenceBinariesDirPath
    ;({ default: APIClass } = await import(pathToFileURL(referenceAPIPath).href))
  } else {
    globalThis.texts.getBinariesDirPath = () => path.join(repoRoot, 'binaries')
    ;({ default: APIClass } = await import('../src/api.ts'))
  }

  const api = new APIClass('default')
  await api.init({}, { accountID: 'default', dataDirPath })
  return { api, dataDirPath }
}

const ipcPrefix = '__PARITY_IPC__'

export async function runAPIChild(options) {
  let api
  let dataDirPath
  try {
    ;({ api, dataDirPath } = await createAPI(options))
    console.log(`${ipcPrefix}${JSON.stringify({ type: 'ready' })}`)
    const lines = readline.createInterface({ input: process.stdin })
    for await (const line of lines) {
      if (!line.trim()) continue
      const request = JSON.parse(line)
      if (request.method === 'dispose') {
        console.log(`${ipcPrefix}${JSON.stringify({ id: request.id, ok: true, ms: 0 })}`)
        break
      }
      const result = await timedCall(() => api[request.method](...(request.args ?? [])))
      if (result.ok) {
        console.log(`${ipcPrefix}${JSON.stringify({ id: request.id, ok: true, value: result.value, ms: result.ms })}`)
      } else {
        console.log(`${ipcPrefix}${JSON.stringify({ id: request.id, ok: false, error: serializeError(result.error), ms: result.ms })}`)
      }
    }
  } finally {
    await Promise.resolve(api?.dispose?.()).catch(() => {})
    if (dataDirPath) await fs.rm(dataDirPath, { recursive: true, force: true }).catch(() => {})
  }
}

export function spawnAPIChild({
  role,
  entrypointPath,
  repoRoot,
  referenceAPIPath,
  referenceBinariesDirPath,
}) {
  const childArgs = [
    entrypointPath,
    ...process.argv.slice(2)
      .filter(arg => !arg.startsWith('--child-role'))
      .filter(arg => !arg.startsWith('--reference-api-bundle'))
      .filter(arg => !arg.startsWith('--reference-binaries-dir')),
    `--child-role=${role}`,
    `--reference-api-bundle=${referenceAPIPath}`,
    `--reference-binaries-dir=${referenceBinariesDirPath}`,
  ]
  const child = spawn(process.execPath, childArgs, {
    cwd: repoRoot,
    env: process.env,
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  let nextID = 1
  let readyResolve
  let readyReject
  let exited = false
  const pending = new Map()
  const ready = new Promise((resolve, reject) => {
    readyResolve = resolve
    readyReject = reject
  })

  child.stderr.on('data', chunk => process.stderr.write(chunk))

  readline.createInterface({ input: child.stdout }).on('line', line => {
    if (!line.startsWith(ipcPrefix)) {
      process.stderr.write(`${line}\n`)
      return
    }
    let message
    try {
      message = JSON.parse(line.slice(ipcPrefix.length))
    } catch (error) {
      readyReject(error)
      return
    }
    if (message.type === 'ready') {
      readyResolve()
      return
    }

    const request = pending.get(message.id)
    if (!request) return
    pending.delete(message.id)
    if (message.ok) {
      request.resolve({ ok: true, value: message.value, ms: message.ms })
    } else {
      request.resolve({ ok: false, error: deserializeError(message.error), ms: message.ms })
    }
  })

  child.on('exit', (code, signal) => {
    exited = true
    const error = new Error(`${role} parity child exited with ${signal ?? code}`)
    readyReject(error)
    for (const request of pending.values()) request.reject(error)
    pending.clear()
  })

  const call = (method, ...methodArgs) => {
    if (exited) return Promise.reject(new Error(`${role} parity child is not running`))
    const id = nextID++
    const payload = JSON.stringify({ id, method, args: methodArgs })
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject })
      child.stdin.write(`${payload}\n`, error => {
        if (!error) return
        pending.delete(id)
        reject(error)
      })
    })
  }

  const callValue = (method, ...methodArgs) => call(method, ...methodArgs).then(result => {
    if (!result.ok) throw result.error
    return result.value
  })

  return {
    role,
    child,
    ready,
    api: {
      getThreads: (...methodArgs) => callValue('getThreads', ...methodArgs),
      getThread: (...methodArgs) => callValue('getThread', ...methodArgs),
      getMessages: (...methodArgs) => callValue('getMessages', ...methodArgs),
      getMessage: (...methodArgs) => callValue('getMessage', ...methodArgs),
      searchMessages: (...methodArgs) => callValue('searchMessages', ...methodArgs),
      dispose: () => call('dispose').catch(() => {}),
    },
  }
}

export async function closeAPIChildren(children) {
  await Promise.all(children.map(childAPI => Promise.resolve(childAPI.api.dispose?.()).catch(() => {})))
  for (const childAPI of children) {
    if (!childAPI.child.killed) childAPI.child.kill()
  }
}
