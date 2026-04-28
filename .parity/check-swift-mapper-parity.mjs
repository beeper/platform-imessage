import { app } from 'electron'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'

import * as platformTestLib from '@textshq/platform-test-lib'

import {
  ensureReferenceAPI,
  formatLimit,
  getArg,
  parseArgs,
  parseLimit,
  unwrapDefault,
} from './parity-utils.mjs'
import parityDiff from './parity-diff.cjs'
import {
  closeAPIChildren,
  spawnAPIChild,
  timedCall,
  runAPIChild,
} from './parity-child-processes.mjs'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.basename(scriptDir) === 'scripts' ? path.resolve(scriptDir, '..') : process.cwd()
const injectGlobals = unwrapDefault(platformTestLib)
const {
  diffParityValues,
  normalizeForParityDelta,
} = parityDiff

const args = parseArgs(process.argv.slice(2))

const referenceRoot = path.resolve(args.get('reference-root') ?? path.join(repoRoot, '.parity/platform-imessage-main'))
const defaultReferenceIMessageNodePath = path.join(referenceRoot, 'binaries', `${process.platform}-${process.arch}`, 'IMessage.node')
const referenceIMessageNodePath = args.get('reference-swift-server-node') ?? defaultReferenceIMessageNodePath
const referenceBinariesDirPath = args.get('reference-binaries-dir') ?? path.dirname(path.dirname(referenceIMessageNodePath))

process.env.IMESSAGE_SKIP_EAGER_MC ??= '1'
process.env.IMESSAGE_STRIP_INTERNAL_FIELDS ??= '1'
process.env.IMESSAGE_SWIFT_MAP_MESSAGE_STRICT ??= '1'

injectGlobals(true, false, repoRoot)

const chatLimit = parseLimit(getArg(args, 'max-chats', 'chats') ?? 'all', '--max-chats')
const skipChats = parseLimit(args.get('skip-chats') ?? '0', '--skip-chats')
if (!Number.isFinite(skipChats)) throw new Error('--skip-chats must be a non-negative integer')
const messageLimit = parseLimit(getArg(args, 'max-messages-per-chat', 'max-messages', 'messages') ?? '100', '--max-messages-per-chat')
const getMessageSamplesArg = args.get('get-message-samples') ?? '1'
const getMessageSamplesAll = getMessageSamplesArg === 'all'
const getMessageSamples = getMessageSamplesAll ? Infinity : Number.parseInt(getMessageSamplesArg, 10)
const progressEvery = Number.parseInt(args.get('progress-every') ?? '10', 10)
const callTimeoutMs = Number.parseInt(args.get('call-timeout-ms') ?? '5000', 10)
if (!Number.isFinite(callTimeoutMs) || callTimeoutMs < 0) throw new Error('--call-timeout-ms must be a non-negative integer')
const traceCurrent = args.has('trace-current')
const forwardChildOutput = args.has('forward-child-output')
const includeDiffValues = args.has('include-diff-values')
const childRole = args.get('child-role')
if (childRole && !['current', 'reference'].includes(childRole)) {
  throw new Error('--child-role must be one of: current, reference')
}
const perfDeltaMinMs = Number.parseFloat(args.get('perf-delta-ms') ?? '25')
const perfDeltaMinRatio = Number.parseFloat(args.get('perf-delta-ratio') ?? '1.25')
const perfDeltaLimit = Number.parseInt(args.get('perf-delta-limit') ?? '20', 10)
const searchSamples = Number.parseInt(args.get('search-samples') ?? '25', 10)
const searchScopes = (args.get('search-scopes') ?? 'global,thread')
  .split(',')
  .map(scope => scope.trim())
  .filter(Boolean)
const explicitThreadIDs = (args.get('thread-ids') ?? '')
  .split(',')
  .map(threadID => threadID.trim())
  .filter(Boolean)

function failureSummary(error) {
  return { details: error instanceof Error ? error.message : String(error) }
}

function valueAtPath(value, pathName) {
  if (pathName === '$') return value
  let cursor = value
  const matcher = /\.([^\.\[]+)|\[(\d+)\]/g
  for (const match of pathName.matchAll(matcher)) {
    if (cursor == null) return undefined
    const key = match[1] ?? Number.parseInt(match[2], 10)
    cursor = cursor[key]
  }
  return cursor
}

function isMissingReferenceSearchMessages(error) {
  return /searchMessages is not a function/.test(error instanceof Error ? error.message : String(error))
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
  const currentResult = await timedCall(currentFn)
  const referenceResult = await timedCall(referenceFn)
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
  const normalizedSwiftOutput = normalizeForParityDelta(phase, swiftOutput)
  const normalizedReferenceOutput = normalizeForParityDelta(phase, referenceOutput)
  const diffs = diffParityValues(normalizedSwiftOutput, normalizedReferenceOutput)
  if (diffs.length === 0) return
  const failure = {
    phase,
    ...context,
    details: diffs.map(delta => `${delta.path}:${delta.kind}`).join(','),
  }
  if (includeDiffValues) {
    failure.values = Object.fromEntries(diffs.map(delta => [delta.path, {
      current: valueAtPath(normalizedSwiftOutput, delta.path),
      reference: valueAtPath(normalizedReferenceOutput, delta.path),
    }]))
  }
  failures.push(failure)
}

function searchTermsFromMessage(message) {
  const text = typeof message?.text === 'string' ? message.text : ''
  const matches = text.match(/[A-Za-z0-9][A-Za-z0-9'._@+-]{2,}/g) ?? []
  return matches
    .filter(term => term.length <= 32 && /[A-Za-z]/.test(term))
    .filter(term => !term.includes('{{') && !term.includes('}}'))
}

if (childRole) {
  await runAPIChild({
    role: childRole,
    repoRoot,
    referenceAPIPath: args.get('reference-api-bundle'),
    referenceBinariesDirPath,
  })
  process.exit(0)
}

const referenceAPIPath = await ensureReferenceAPI({
  args,
  repoRoot,
  referenceRoot,
  referenceBinariesDirPath,
})
const childAPIs = [
  spawnAPIChild({
    role: 'current',
    entrypointPath: fileURLToPath(import.meta.url),
    repoRoot,
    referenceAPIPath,
    referenceBinariesDirPath,
    forwardChildOutput,
    callTimeoutMs,
  }),
  spawnAPIChild({
    role: 'reference',
    entrypointPath: fileURLToPath(import.meta.url),
    repoRoot,
    referenceAPIPath,
    referenceBinariesDirPath,
    forwardChildOutput,
    callTimeoutMs,
  }),
]
let isClosingChildren = false
async function closeChildrenAndExit(exitCode) {
  if (isClosingChildren) return
  isClosingChildren = true
  await closeAPIChildren(childAPIs)
  app.exit(exitCode)
}
process.once('SIGINT', () => {
  closeChildrenAndExit(130).finally(() => process.exit(130))
})
process.once('SIGTERM', () => {
  closeChildrenAndExit(143).finally(() => process.exit(143))
})
await Promise.all(childAPIs.map(child => child.ready))
const api = childAPIs[0].api
const referenceAPI = childAPIs[1].api

try {
  const threads = explicitThreadIDs.map(id => ({ id }))
  const failures = []
  let threadCursor
  let threadPagesChecked = 0
  let getThreadsPagesChecked = 0
  const targetThreadCount = Number.isFinite(chatLimit) ? skipChats + chatLimit : Infinity
  while (explicitThreadIDs.length === 0 && threads.length < targetThreadCount) {
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
  let searchMessagesChecked = 0
  let usesReferenceSearchFallback = false
  const searchCandidates = []
  const searchCandidateKeys = new Set()

  function addSearchCandidates(thread, messages) {
    if (searchCandidates.length >= searchSamples) return
    for (const message of messages) {
      for (const query of searchTermsFromMessage(message)) {
        const key = `${thread.id}:${query.toLowerCase()}`
        if (searchCandidateKeys.has(key)) continue
        searchCandidateKeys.add(key)
        searchCandidates.push({
          query,
          threadID: thread.id,
          messageID: message.id,
          queryLength: query.length,
        })
        if (searchCandidates.length >= searchSamples) return
      }
    }
  }

  const selectedThreads = explicitThreadIDs.length > 0
    ? threads
    : (Number.isFinite(chatLimit)
      ? threads.slice(skipChats, skipChats + chatLimit)
      : threads.slice(skipChats))
  for (const [index, thread] of selectedThreads.entries()) {
    const checkedThreadCount = index + 1
    const threadIndex = skipChats + checkedThreadCount
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
        const messagesToCheck = Number.isFinite(messageLimit)
          ? page.items.slice(0, Math.max(0, messageLimit - seenMessages))
          : page.items
        mappedMessagesPlanned += messagesToCheck.length
        seenMessages += messagesToCheck.length
        recordDelta(failures, 'getMessages', { threadID: thread.id, pageIndex }, page, referencePage)
        addSearchCandidates(thread, messagesToCheck)

        const sampledMessages = Number.isFinite(getMessageSamples)
          ? messagesToCheck.slice(0, Math.max(0, getMessageSamples))
          : messagesToCheck
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
    if (progressEvery > 0 && checkedThreadCount % progressEvery === 0) {
      console.error(`[parity] checked ${checkedThreadCount}/${selectedThreads.length} chats (thread ${threadIndex})`)
    }
  }

  async function referenceSearchFromCurrentResults(currentSearch, options) {
    const items = []
    for (const item of currentSearch.items) {
      if (!item?.threadID || !item?.id) continue
      const message = await referenceAPI.getMessage(item.threadID, item.id)
      if (!message) continue
      if (options?.threadID) {
        items.push(message)
      } else {
        const messageWithoutReactions = { ...message }
        delete messageWithoutReactions.reactions
        items.push(messageWithoutReactions)
      }
    }
    return {
      items,
      hasMore: currentSearch.hasMore,
      oldestCursor: currentSearch.oldestCursor,
    }
  }

  async function timedSearchPair(context, query, options) {
    const currentResult = await timedCall(() => api.searchMessages(query, undefined, options))
    if (!currentResult.ok) throw currentResult.error

    if (!usesReferenceSearchFallback) {
      const referenceResult = await timedCall(() => referenceAPI.searchMessages(query, undefined, options))
      if (referenceResult.ok) {
        recordPerfDelta('searchMessages', context, currentResult.ms, referenceResult.ms)
        return [currentResult.value, referenceResult.value]
      }
      if (!isMissingReferenceSearchMessages(referenceResult.error)) {
        recordPerfDelta('searchMessages', context, currentResult.ms, referenceResult.ms)
        throw referenceResult.error
      }
      usesReferenceSearchFallback = true
    }

    const referenceResult = await timedCall(() => referenceSearchFromCurrentResults(currentResult.value, options))
    recordPerfDelta('searchMessages', { ...context, referenceMode: 'current-search-results' }, currentResult.ms, referenceResult.ms)
    if (!referenceResult.ok) throw referenceResult.error
    return [currentResult.value, referenceResult.value]
  }

  const runSearchScope = async (candidate, searchIndex, scope) => {
    const options = scope === 'thread' ? { threadID: candidate.threadID } : undefined
    const context = {
      searchIndex,
      scope,
      queryLength: candidate.queryLength,
      messageID: candidate.messageID,
      ...(scope === 'thread' ? { threadID: candidate.threadID } : {}),
    }
    try {
      const [currentSearch, referenceSearch] = await timedSearchPair(context, candidate.query, options)
      searchMessagesChecked += 1
      recordDelta(failures, 'searchMessages', context, currentSearch, referenceSearch)
    } catch (error) {
      searchMessagesChecked += 1
      failures.push({ phase: 'searchMessages', ...context, ...failureSummary(error) })
    }
  }

  for (const [index, candidate] of searchCandidates.entries()) {
    const searchIndex = index + 1
    for (const scope of searchScopes) {
      if (scope !== 'global' && scope !== 'thread') continue
      await runSearchScope(candidate, searchIndex, scope)
    }
  }

  const byDiff = Object.create(null)
  for (const failure of failures) {
    byDiff[failure.details] = (byDiff[failure.details] ?? 0) + 1
  }

  console.log(JSON.stringify({
    chatLimit: formatLimit(chatLimit),
    skipChats,
    messageLimitPerChat: formatLimit(messageLimit),
    processMode: 'child-processes',
    totalChatsDiscovered: threads.length,
    chatsChecked: selectedThreads.length,
    threadPagesChecked,
    getThreadsPagesChecked,
    getThreadItemsChecked,
    pagesChecked,
    getMessagesPagesChecked,
    getMessageItemsChecked,
    searchMessagesChecked,
    searchCandidatesCollected: searchCandidates.length,
    referenceSearchMode: usesReferenceSearchFallback ? 'current-search-results' : 'api',
    mappedMessagesPlanned,
    strictFailures: failures.length,
    byDiff,
    perfDeltas: summarizePerfDeltas(),
    failures,
  }, null, 2))

  process.exitCode = failures.length === 0 ? 0 : 1
} finally {
  await closeAPIChildren(childAPIs)
  app.exit(process.exitCode ?? 0)
}
