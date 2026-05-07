#!/usr/bin/env node
import { execFileSync, spawnSync } from 'node:child_process'
import * as fsSync from 'node:fs'
import * as fs from 'node:fs/promises'
import * as os from 'node:os'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '..')
const productName = 'IMessagePerfBench'

const args = parseArgs(process.argv.slice(2))
const noBuild = args.has('no-build')
const debug = args.has('debug')
const jsonOutput = args.has('json')
const withParity = args.has('with-parity') || args.has('parity-only')
const parityOnly = args.has('parity-only')
const configuration = debug ? 'debug' : 'release'

if (args.has('help')) {
  printHelp()
  process.exit(0)
}

const output = {
  swift: null,
  parity: null,
}

if (!parityOnly) {
  if (!noBuild) buildSwiftBench()
  output.swift = runSwiftBench()
}

if (withParity) {
  output.parity = await runParity()
}

if (jsonOutput) {
  console.log(JSON.stringify(output, null, 2))
} else {
  if (output.swift) printSwiftReport(output.swift)
  if (output.parity) printParityReport(output.parity)
}

function parseArgs(argv) {
  const parsed = new Map()
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    const equalsMatch = arg.match(/^--([^=]+)=(.*)$/)
    if (equalsMatch) {
      parsed.set(equalsMatch[1], equalsMatch[2])
      continue
    }
    const flagMatch = arg.match(/^--(.+)$/)
    if (!flagMatch) continue

    const name = flagMatch[1]
    const next = argv[index + 1]
    if (next && !next.startsWith('--') && optionTakesValue(name)) {
      parsed.set(name, next)
      index += 1
    } else {
      parsed.set(name, '1')
    }
  }
  return parsed
}

function optionTakesValue(name) {
  return [
    'messages-dir',
    'iterations',
    'warmups',
    'max-chats',
    'message-limit',
    'api-thread-samples',
    'search-query',
    'api-timeout-ms',
    'parity-timeout-ms',
    'parity-max-chats',
    'parity-max-messages-per-chat',
    'get-message-samples',
    'search-samples',
    'progress-every',
    'reference-root',
    'reference-ref',
    'reference-swift-server-node',
    'reference-binaries-dir',
  ].includes(name)
}

function buildSwiftBench() {
  run('swift', ['build', '-c', configuration, '--product', productName], { stdio: 'inherit' })
}

function runSwiftBench() {
  const binDir = execFileSync('swift', [
    'build',
    '-c',
    configuration,
    '--product',
    productName,
    '--show-bin-path',
  ], { cwd: repoRoot, encoding: 'utf8' }).trim()
  const binPath = path.join(binDir, productName)
  const swiftArgs = ['--format', 'json']

  for (const name of [
    'messages-dir',
    'iterations',
    'warmups',
    'max-chats',
    'message-limit',
    'api-thread-samples',
    'search-query',
  ]) {
    if (args.has(name)) swiftArgs.push(`--${name}`, args.get(name))
  }
  for (const name of ['create-indexes', 'sql-only', 'api-only']) {
    if (args.has(name)) swiftArgs.push(`--${name}`)
  }

  const result = spawnSync(binPath, swiftArgs, {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  if (result.error) {
    throw result.error
  }
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '')
    process.stderr.write(result.stderr ?? '')
    process.exit(result.status ?? 1)
  }

  try {
    return JSON.parse(result.stdout)
  } catch (error) {
    process.stderr.write(result.stdout ?? '')
    throw new Error(`Could not parse ${productName} JSON output: ${error.message}`)
  }
}

async function runParity() {
  if (!noBuild) {
    run('yarn', ['build:swift-mapper-parity'], { stdio: 'inherit' })
  }

  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'imessage-perf-parity-'))
  const outputJSONPath = path.join(tempDir, 'parity.json')
  const parityArgs = [
    '.parity/check-swift-mapper-parity.compiled.mjs',
    `--output-json=${outputJSONPath}`,
    '--no-stdout-json',
    `--max-chats=${args.get('parity-max-chats') ?? args.get('max-chats') ?? '5'}`,
    `--max-messages-per-chat=${args.get('parity-max-messages-per-chat') ?? args.get('message-limit') ?? '20'}`,
    `--get-message-samples=${args.get('get-message-samples') ?? '0'}`,
    `--search-samples=${args.get('search-samples') ?? '0'}`,
    `--progress-every=${args.get('progress-every') ?? '1'}`,
    `--call-timeout-ms=${args.get('api-timeout-ms') ?? '5000'}`,
  ]

  for (const name of [
    'reference-root',
    'reference-ref',
    'reference-swift-server-node',
    'reference-binaries-dir',
  ]) {
    if (args.has(name)) parityArgs.push(`--${name}=${args.get(name)}`)
  }
  for (const name of ['skip-reference-rebuild', 'rebuild-reference', 'forward-child-output']) {
    if (args.has(name)) parityArgs.push(`--${name}`)
  }

  const parityTimeoutMs = Number.parseInt(args.get('parity-timeout-ms') ?? '120000', 10)
  const result = spawnSync(resolveElectron(), parityArgs, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: Number.isFinite(parityTimeoutMs) ? parityTimeoutMs : undefined,
    killSignal: 'SIGTERM',
  })
  if (result.error?.code === 'ETIMEDOUT') {
    process.stderr.write(`Parity run timed out after ${parityTimeoutMs}ms. Increase --parity-timeout-ms or run the parity command directly with --forward-child-output.\n`)
    process.exit(124)
  }
  if (result.error) {
    throw result.error
  }
  if (result.stdout) process.stderr.write(result.stdout)
  if (result.status !== 0) {
    process.stderr.write(result.stderr ?? '')
    process.exit(result.status ?? 1)
  }

  try {
    return JSON.parse(await fs.readFile(outputJSONPath, 'utf8'))
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true }).catch(() => {})
  }
}

function run(command, commandArgs, options = {}) {
  const result = spawnSync(command, commandArgs, {
    cwd: repoRoot,
    encoding: 'utf8',
    ...options,
  })
  if (result.error) {
    throw result.error
  }
  if (result.status !== 0) {
    if (result.stdout) process.stderr.write(result.stdout)
    if (result.stderr) process.stderr.write(result.stderr)
    process.exit(result.status ?? 1)
  }
  return result
}

function resolveBin(name) {
  const localPath = path.join(repoRoot, 'node_modules', '.bin', name)
  return fsSync.existsSync(localPath) ? localPath : name
}

function resolveElectron() {
  const macElectronPath = path.join(
    repoRoot,
    'node_modules',
    'electron',
    'dist',
    'Electron.app',
    'Contents',
    'MacOS',
    'Electron',
  )
  return fsSync.existsSync(macElectronPath) ? macElectronPath : resolveBin('electron')
}

function printSwiftReport(report) {
  console.log(bold('iMessage performance benchmarks'))
  console.log(dim(`messages dir: ${shortenHome(report.metadata.messagesDir)}`))
  console.log(dim(`iterations: ${report.metadata.iterations}, warmups: ${report.metadata.warmups}`))
  console.log()
  printBenchTable('SQL hot paths', report.sql.results)
  console.log()
  printBenchTable('Platform API', report.api.results)
}

function printBenchTable(title, results) {
  console.log(bold(title))
  if (!results?.length) {
    console.log(dim('skipped'))
    return
  }
  printTable([
    ['name', 'rows', 'avg ms', 'p50 ms', 'p95 ms', 'min ms', 'max ms'],
    ...results.map(result => [
      result.name,
      String(result.resultCount),
      formatMS(result.averageMS),
      formatMS(result.p50MS),
      formatMS(result.p95MS),
      formatMS(result.minMS),
      formatMS(result.maxMS),
    ]),
  ], { numericColumns: new Set([1, 2, 3, 4, 5, 6]) })
}

function printParityReport(report) {
  console.log()
  console.log(bold('Parity API comparison'))
  console.log(dim(`checked chats: ${report.chatsChecked}, getThreads pages: ${report.getThreadsPagesChecked}, getMessages pages: ${report.getMessagesPagesChecked}`))
  if (report.strictFailures > 0) {
    console.log(red(`strict failures: ${report.strictFailures}`))
  } else {
    console.log(green('strict failures: 0'))
  }

  const byPhase = report.perfDeltas?.byPhase ?? {}
  const rows = Object.entries(byPhase).map(([phase, value]) => [
    phase,
    String(value.samples),
    formatMS(value.avgCurrentMs),
    formatMS(value.avgReferenceMs),
    formatMS(value.avgDeltaMs),
    value.aggregateRatio == null ? '-' : value.aggregateRatio.toFixed(3),
  ])
  if (rows.length) {
    printTable([
      ['phase', 'samples', 'current avg', 'reference avg', 'delta avg', 'ratio'],
      ...rows,
    ], { numericColumns: new Set([1, 2, 3, 4, 5]) })
  }
}

function printTable(rows, { numericColumns = new Set() } = {}) {
  const widths = []
  for (const row of rows) {
    row.forEach((cell, index) => {
      widths[index] = Math.max(widths[index] ?? 0, visibleLength(cell))
    })
  }
  rows.forEach((row, rowIndex) => {
    const line = row.map((cell, index) => {
      const padding = ' '.repeat(widths[index] - visibleLength(cell))
      return numericColumns.has(index) ? `${padding}${cell}` : `${cell}${padding}`
    }).join('  ')
    console.log(rowIndex === 0 ? dim(line) : line)
  })
}

function printHelp() {
  console.log(`Usage: yarn perf:imessage [options]

Runs backend-agnostic IMDatabase hot-path benchmarks and PlatformAPI getThreads/getMessages timings.

Common options:
  --iterations <n>                 Measured iterations per case
  --warmups <n>                    Warmup iterations per case
  --max-chats <n>                  Chats sampled by SQL benchmarks
  --message-limit <n>              Messages sampled per chat
  --api-thread-samples <n>         Threads sampled by PlatformAPI.getMessages
  --sql-only                       Skip PlatformAPI benchmarks
  --api-only                       Skip SQL hot-path benchmarks
  --create-indexes                 Ask IMDatabase to create optional read indexes
  --with-parity                    Also run the current-vs-reference parity script
  --parity-timeout-ms <n>          Overall timeout for --with-parity
  --json                           Emit machine-readable JSON
  --no-build                       Reuse existing built artifacts
`)
}

function formatMS(value) {
  return Number(value).toFixed(3)
}

function shortenHome(value) {
  return value.replace(os.homedir(), '~')
}

function visibleLength(value) {
  return String(value).replace(/\u001b\[[0-9;]*m/g, '').length
}

function color(open, close, value) {
  if (!process.stdout.isTTY) return value
  return `${open}${value}${close}`
}

function bold(value) {
  return color('\u001b[1m', '\u001b[0m', value)
}

function dim(value) {
  return color('\u001b[2m', '\u001b[0m', value)
}

function red(value) {
  return color('\u001b[31m', '\u001b[0m', value)
}

function green(value) {
  return color('\u001b[32m', '\u001b[0m', value)
}
