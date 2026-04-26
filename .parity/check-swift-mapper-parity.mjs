import { app } from 'electron'
import { execFileSync } from 'node:child_process'
import * as fs from 'node:fs/promises'
import * as os from 'node:os'
import * as path from 'node:path'
import { performance } from 'node:perf_hooks'
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
const perfDeltaMinMs = Number.parseFloat(args.get('perf-delta-ms') ?? '25')
const perfDeltaMinRatio = Number.parseFloat(args.get('perf-delta-ratio') ?? '1.25')
const perfDeltaLimit = Number.parseInt(args.get('perf-delta-limit') ?? '20', 10)

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

const roundTiming = value => Number(value.toFixed(3))
const perfRatio = (currentMs, referenceMs) => {
  if (referenceMs === 0) return currentMs === 0 ? 1 : null
  return currentMs / referenceMs
}

const perfDeltasByPhase = new Map()
const currentSlowerPerfDeltas = []
const referenceSlowerPerfDeltas = []

function boundedSortPush(list, entry, sortKey) {
  if (perfDeltaLimit <= 0) return
  list.push(entry)
  list.sort((a, b) => b[sortKey] - a[sortKey])
  if (list.length > perfDeltaLimit) list.length = perfDeltaLimit
}

function isNotablePerfDelta(deltaMs, ratio) {
  return deltaMs >= perfDeltaMinMs && (ratio === null || ratio >= perfDeltaMinRatio)
}

async function timedCall(fn) {
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

function recordPerfDelta(phase, context, currentMs, referenceMs) {
  const bucket = perfDeltasByPhase.get(phase) ?? {
    samples: 0,
    currentTotalMs: 0,
    referenceTotalMs: 0,
    deltaTotalMs: 0,
    currentSlowerCount: 0,
    referenceSlowerCount: 0,
    maxCurrentSlowerMs: 0,
    maxReferenceSlowerMs: 0,
  }
  const deltaMs = currentMs - referenceMs
  const ratio = perfRatio(currentMs, referenceMs)
  bucket.samples += 1
  bucket.currentTotalMs += currentMs
  bucket.referenceTotalMs += referenceMs
  bucket.deltaTotalMs += deltaMs
  if (deltaMs > 0) {
    bucket.currentSlowerCount += 1
    bucket.maxCurrentSlowerMs = Math.max(bucket.maxCurrentSlowerMs, deltaMs)
    if (isNotablePerfDelta(deltaMs, ratio)) {
      boundedSortPush(currentSlowerPerfDeltas, {
        phase,
        ...context,
        currentMs: roundTiming(currentMs),
        referenceMs: roundTiming(referenceMs),
        deltaMs: roundTiming(deltaMs),
        ratio: ratio === null ? null : Number(ratio.toFixed(3)),
      }, 'deltaMs')
    }
  } else if (deltaMs < 0) {
    const referenceDeltaMs = -deltaMs
    const referenceRatio = perfRatio(referenceMs, currentMs)
    bucket.referenceSlowerCount += 1
    bucket.maxReferenceSlowerMs = Math.max(bucket.maxReferenceSlowerMs, referenceDeltaMs)
    if (isNotablePerfDelta(referenceDeltaMs, referenceRatio)) {
      boundedSortPush(referenceSlowerPerfDeltas, {
        phase,
        ...context,
        currentMs: roundTiming(currentMs),
        referenceMs: roundTiming(referenceMs),
        deltaMs: roundTiming(deltaMs),
        referenceSlowerByMs: roundTiming(referenceDeltaMs),
        ratio: referenceRatio === null ? null : Number(referenceRatio.toFixed(3)),
      }, 'referenceSlowerByMs')
    }
  }
  perfDeltasByPhase.set(phase, bucket)
}

async function timedPair(phase, context, currentFn, referenceFn) {
  const [currentResult, referenceResult] = await Promise.all([
    timedCall(currentFn),
    timedCall(referenceFn),
  ])
  recordPerfDelta(phase, context, currentResult.ms, referenceResult.ms)
  if (!currentResult.ok) throw currentResult.error
  if (!referenceResult.ok) throw referenceResult.error
  return [currentResult.value, referenceResult.value]
}

function summarizePerfDeltas() {
  return {
    thresholds: {
      minMs: perfDeltaMinMs,
      minRatio: perfDeltaMinRatio,
      limit: perfDeltaLimit,
    },
    byPhase: Object.fromEntries(
      [...perfDeltasByPhase.entries()]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([phase, bucket]) => [phase, {
          samples: bucket.samples,
          currentTotalMs: roundTiming(bucket.currentTotalMs),
          referenceTotalMs: roundTiming(bucket.referenceTotalMs),
          totalDeltaMs: roundTiming(bucket.deltaTotalMs),
          avgCurrentMs: roundTiming(bucket.currentTotalMs / bucket.samples),
          avgReferenceMs: roundTiming(bucket.referenceTotalMs / bucket.samples),
          avgDeltaMs: roundTiming(bucket.deltaTotalMs / bucket.samples),
          aggregateRatio: bucket.referenceTotalMs === 0 ? null : Number((bucket.currentTotalMs / bucket.referenceTotalMs).toFixed(3)),
          currentSlowerCount: bucket.currentSlowerCount,
          referenceSlowerCount: bucket.referenceSlowerCount,
          maxCurrentSlowerMs: roundTiming(bucket.maxCurrentSlowerMs),
          maxReferenceSlowerMs: roundTiming(bucket.maxReferenceSlowerMs),
        }]),
    ),
    currentSlower: currentSlowerPerfDeltas,
    referenceSlower: referenceSlowerPerfDeltas,
  }
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
  let getThreadsPagesChecked = 0
  while (threads.length < skipChats + chatLimit) {
    let page
    try {
      const pagination = threadCursor ? { cursor: threadCursor, direction: 'before' } : undefined
      const pageIndex = threadPagesChecked + 1
      const [currentPage, referencePage] = await timedPair(
        'getThreads',
        { pageIndex },
        () => api.getThreads('normal', pagination),
        () => referenceAPI.getThreads('normal', pagination),
      )
      page = currentPage
      threadPagesChecked += 1
      getThreadsPagesChecked += 1
      recordDelta(failures, 'getThreads', { pageIndex }, currentPage, referencePage)
    } catch (error) {
      threadPagesChecked += 1
      getThreadsPagesChecked += 1
      failures.push({ phase: 'getThreads', pageIndex: threadPagesChecked, ...failureSummary(error) })
      break
    }
    threads.push(...page.items.filter(thread => !threads.some(existing => existing.id === thread.id)))
    threadCursor = page.oldestCursor
    if (!page.hasMore || !threadCursor) break
  }

  let pagesChecked = 0
  let getMessagesPagesChecked = 0
  let getMessageItemsChecked = 0
  let getThreadItemsChecked = 0
  let mappedMessagesPlanned = 0

  const selectedThreads = threads.slice(skipChats, skipChats + chatLimit)
  for (const [index, thread] of selectedThreads.entries()) {
    const threadIndex = skipChats + index + 1
    if (progressEvery > 0 && threadIndex % progressEvery === 0) {
      console.error(`[parity] checked ${threadIndex}/${threads.length} chats`)
    }
    try {
      const [currentThread, referenceThread] = await timedPair(
        'getThread',
        { threadID: thread.id },
        () => api.getThread(thread.id),
        () => referenceAPI.getThread(thread.id),
      )
      getThreadItemsChecked += 1
      recordDelta(failures, 'getThread', { threadID: thread.id }, currentThread, referenceThread)
    } catch (error) {
      getThreadItemsChecked += 1
      failures.push({ phase: 'getThread', threadID: thread.id, ...failureSummary(error) })
    }
    let messageCursor
    let seenMessages = 0
    while (seenMessages < messageLimit) {
      try {
        if (traceCurrent) {
          console.error(`[parity] chat=${threadIndex} thread=${thread.id} cursor=${messageCursor ?? '<latest>'}`)
        }
        const pagination = messageCursor ? { cursor: messageCursor, direction: 'before' } : undefined
        const pageIndex = pagesChecked + 1
        const [page, referencePage] = await timedPair(
          'getMessages',
          { threadID: thread.id, pageIndex },
          () => api.getMessages(thread.id, pagination),
          () => referenceAPI.getMessages(thread.id, pagination),
        )
        pagesChecked += 1
        getMessagesPagesChecked += 1
        mappedMessagesPlanned += page.items.length
        seenMessages += page.items.length
        recordDelta(failures, 'getMessages', { threadID: thread.id, pageIndex }, page, referencePage)

        const sampledMessages = Number.isFinite(getMessageSamples)
          ? page.items.slice(0, Math.max(0, getMessageSamples))
          : page.items
        for (const message of sampledMessages) {
          try {
            const [currentMessage, referenceMessage] = await timedPair(
              'getMessage',
              { threadID: thread.id, messageID: message.id },
              () => api.getMessage(thread.id, message.id),
              () => referenceAPI.getMessage(thread.id, message.id),
            )
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
    getThreadsPagesChecked,
    getThreadItemsChecked,
    pagesChecked,
    getMessagesPagesChecked,
    getMessageItemsChecked,
    mappedMessagesPlanned,
    strictFailures: failures.length,
    byDiff,
    perfDeltas: summarizePerfDeltas(),
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
