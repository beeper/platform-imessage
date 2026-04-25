import { app } from 'electron'
import { execFileSync } from 'node:child_process'
import * as fs from 'node:fs/promises'
import * as os from 'node:os'
import * as path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import * as platformTestLib from '@textshq/platform-test-lib'

const unwrapDefault = value => {
  let current = value
  while (current && typeof current !== 'function' && 'default' in current) {
    current = current.default
  }
  return current
}

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.basename(scriptDir) === 'scripts' ? path.resolve(scriptDir, '..') : process.cwd()
const injectGlobals = unwrapDefault(platformTestLib)

process.env.IMESSAGE_SKIP_EAGER_MC ??= '1'
process.env.IMESSAGE_STRIP_INTERNAL_FIELDS ??= '1'
process.env.IMESSAGE_SWIFT_MAP_MESSAGE_STRICT ??= '1'

injectGlobals(true, false, repoRoot)
globalThis.texts.getBinariesDirPath = () => path.join(repoRoot, 'binaries')

const args = new Map(
  process.argv.slice(2).flatMap(arg => {
    const match = arg.match(/^--([^=]+)=(.*)$/)
    if (match) return [[match[1], match[2]]]
    const flag = arg.match(/^--(.+)$/)
    return flag ? [[flag[1], '1']] : []
  }),
)

const binariesDirPathLiteral = JSON.stringify(path.join(repoRoot, 'binaries'))
const buildBanner = `globalThis.texts={IS_DEV:true,isLoggingEnabled:false,log(){},error(){},constants:{USER_AGENT:'platform-imessage-parity',APP_VERSION:'1.0.0'},Sentry:{captureException(){},captureMessage(){},startTransaction(){}},async trackPlatformEvent(){},getBinariesDirPath(){return ${binariesDirPathLiteral}},fetch:globalThis.fetch,fetchStream:undefined,createHttpClient:undefined,nativeFetch:undefined,nativeFetchStream:undefined,runWorker:undefined,forkChildProcess:undefined,getOriginalObject:undefined,openBrowserWindow:undefined};`

async function pathExists(filePath) {
  return fs.access(filePath)
    .then(() => true)
    .catch(() => false)
}

function exec(command, commandArgs, cwd) {
  execFileSync(command, commandArgs, { cwd, stdio: 'inherit' })
}

async function ensureReferenceAPI() {
  const referenceRoot = path.resolve(args.get('reference-root') ?? path.join(repoRoot, '.parity/platform-imessage-main'))
  const referenceRef = args.get('reference-ref') ?? 'main'
  const bundlePath = path.join(referenceRoot, '.parity-platform-api.compiled.mjs')
  if (!await pathExists(path.join(referenceRoot, 'package.json'))) {
    await fs.mkdir(path.dirname(referenceRoot), { recursive: true })
    exec('git', ['worktree', 'add', '--detach', referenceRoot, referenceRef], repoRoot)
  }
  if (args.has('rebuild-reference') || !await pathExists(bundlePath)) {
    exec('bun', [
      'build',
      'src/api.ts',
      '--target=node',
      '--format=esm',
      '--external',
      'electron',
      '--external',
      '@textshq/platform-test-lib',
      '--external',
      'node-mac-permissions',
      '--banner',
      buildBanner,
      '--outfile',
      bundlePath,
    ], referenceRoot)
  }
  return bundlePath
}

const dataDirPath = await fs.mkdtemp(path.join(os.tmpdir(), 'platform-imessage-parity-current-'))
const referenceDataDirPath = await fs.mkdtemp(path.join(os.tmpdir(), 'platform-imessage-parity-reference-'))
const { default: AppleiMessage } = await import('../src/api.ts')
const { default: ReferenceAppleiMessage } = await import(pathToFileURL(await ensureReferenceAPI()).href)
const api = new AppleiMessage('default')
const referenceAPI = new ReferenceAppleiMessage('default')

const chatLimit = Number.parseInt(args.get('chats') ?? '1000', 10)
const skipChats = Number.parseInt(args.get('skip-chats') ?? '0', 10)
const messageLimit = Number.parseInt(args.get('messages') ?? '100', 10)
const getMessageSamplesArg = args.get('get-message-samples') ?? '1'
const getMessageSamplesAll = getMessageSamplesArg === 'all'
const getMessageSamples = getMessageSamplesAll ? Infinity : Number.parseInt(getMessageSamplesArg, 10)
const progressEvery = Number.parseInt(args.get('progress-every') ?? '100', 10)
const traceCurrent = args.has('trace-current')

const dateFields = new Set(['timestamp', 'seen', 'editedTimestamp'])

function normalize(value, key) {
  if (value instanceof Date) return { $date: value.getTime() }
  if (dateFields.has(key) && typeof value === 'number') return { $date: value }
  if (Array.isArray(value)) return value.map(item => normalize(item))
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([entryKey, entryValue]) => entryKey !== '_original' && entryValue !== undefined)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([entryKey, entryValue]) => [entryKey, normalize(entryValue, entryKey)]),
    )
  }
  return value
}

const valueType = value => Array.isArray(value) ? 'array' : value === null ? 'null' : typeof value

function diff(swiftValue, referenceValue, pathName = '$', diffs = []) {
  if (diffs.length >= 20 || Object.is(swiftValue, referenceValue)) return diffs
  const swiftType = valueType(swiftValue)
  const referenceType = valueType(referenceValue)
  if (swiftType !== referenceType) {
    diffs.push({ path: pathName, kind: 'type' })
    return diffs
  }
  if (Array.isArray(swiftValue) && Array.isArray(referenceValue)) {
    if (swiftValue.length !== referenceValue.length) diffs.push({ path: pathName, kind: 'length' })
    for (let index = 0; index < Math.min(swiftValue.length, referenceValue.length); index++) {
      diff(swiftValue[index], referenceValue[index], `${pathName}[${index}]`, diffs)
    }
    return diffs
  }
  if (swiftValue && typeof swiftValue === 'object' && referenceValue && typeof referenceValue === 'object') {
    const keys = new Set([...Object.keys(swiftValue), ...Object.keys(referenceValue)])
    for (const key of [...keys].sort()) {
      if (diffs.length >= 20) break
      if (!(key in swiftValue)) diffs.push({ path: `${pathName}.${key}`, kind: 'missing-in-swift' })
      else if (!(key in referenceValue)) diffs.push({ path: `${pathName}.${key}`, kind: 'missing-in-reference' })
      else diff(swiftValue[key], referenceValue[key], `${pathName}.${key}`, diffs)
    }
    return diffs
  }
  diffs.push({ path: pathName, kind: 'value' })
  return diffs
}

function failureSummary(error) {
  return { details: error instanceof Error ? error.message : String(error) }
}

function recordDelta(failures, phase, context, swiftOutput, referenceOutput) {
  const diffs = diff(normalize(swiftOutput), normalize(referenceOutput))
  if (diffs.length === 0) return
  failures.push({
    phase,
    ...context,
    details: diffs.map(delta => `${delta.path}:${delta.kind}`).join(','),
  })
}

try {
  await api.init({}, { accountID: 'default', dataDirPath })
  await referenceAPI.init({}, { accountID: 'default', dataDirPath: referenceDataDirPath })

  const threads = []
  const failures = []
  let threadCursor
  let threadPagesChecked = 0
  while (threads.length < skipChats + chatLimit) {
    let page
    try {
      page = await api.getThreads(
        'normal',
        threadCursor ? { cursor: threadCursor, direction: 'before' } : undefined,
      )
      threadPagesChecked += 1
    } catch (error) {
      threadPagesChecked += 1
      failures.push({ phase: 'threads', pageIndex: threadPagesChecked, ...failureSummary(error) })
      break
    }
    threads.push(...page.items.filter(thread => !threads.some(existing => existing.id === thread.id)))
    threadCursor = page.oldestCursor
    if (!page.hasMore || !threadCursor) break
  }

  let pagesChecked = 0
  let getMessagesPagesChecked = 0
  let getMessageItemsChecked = 0
  let mappedMessagesPlanned = 0

  const selectedThreads = threads.slice(skipChats, skipChats + chatLimit)
  for (const [index, thread] of selectedThreads.entries()) {
    const threadIndex = skipChats + index + 1
    if (progressEvery > 0 && threadIndex % progressEvery === 0) {
      console.error(`[parity] checked ${threadIndex}/${threads.length} chats`)
    }
    let messageCursor
    let seenMessages = 0
    while (seenMessages < messageLimit) {
      try {
        if (traceCurrent) {
          console.error(`[parity] chat=${threadIndex} thread=${thread.id} cursor=${messageCursor ?? '<latest>'}`)
        }
        const pagination = messageCursor ? { cursor: messageCursor, direction: 'before' } : undefined
        const [page, referencePage] = await Promise.all([
          api.getMessages(thread.id, pagination),
          referenceAPI.getMessages(thread.id, pagination),
        ])
        pagesChecked += 1
        getMessagesPagesChecked += 1
        mappedMessagesPlanned += page.items.length
        seenMessages += page.items.length
        recordDelta(failures, 'getMessages', { threadID: thread.id, pageIndex: pagesChecked }, page, referencePage)

        const sampledMessages = Number.isFinite(getMessageSamples)
          ? page.items.slice(0, Math.max(0, getMessageSamples))
          : page.items
        for (const message of sampledMessages) {
          try {
            const [currentMessage, referenceMessage] = await Promise.all([
              api.getMessage(thread.id, message.id),
              referenceAPI.getMessage(thread.id, message.id),
            ])
            getMessageItemsChecked += 1
            recordDelta(failures, 'getMessage', { threadID: thread.id, messageID: message.id }, currentMessage, referenceMessage)
          } catch (error) {
            getMessageItemsChecked += 1
            failures.push({ phase: 'getMessage', threadID: thread.id, messageID: message.id, ...failureSummary(error) })
          }
        }

        if (!page.hasMore || page.items.length === 0) break
        messageCursor = page.items[0]?.cursor
        if (!messageCursor) break
      } catch (error) {
        pagesChecked += 1
        failures.push({ phase: 'getMessages', threadID: thread.id, pageIndex: pagesChecked, ...failureSummary(error) })
        break
      }
    }
  }

  const byDiff = Object.create(null)
  for (const failure of failures) {
    byDiff[failure.details] = (byDiff[failure.details] ?? 0) + 1
  }

  console.log(JSON.stringify({
    chatsChecked: selectedThreads.length,
    threadPagesChecked,
    pagesChecked,
    getMessagesPagesChecked,
    getMessageItemsChecked,
    mappedMessagesPlanned,
    strictFailures: failures.length,
    byDiff,
    failures,
  }, null, 2))

  process.exitCode = failures.length === 0 ? 0 : 1
} finally {
  await Promise.resolve(api.dispose?.()).catch(() => {})
  await Promise.resolve(referenceAPI.dispose?.()).catch(() => {})
  await fs.rm(dataDirPath, { recursive: true, force: true }).catch(() => {})
  await fs.rm(referenceDataDirPath, { recursive: true, force: true }).catch(() => {})
  app.exit(process.exitCode ?? 0)
}
