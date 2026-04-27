import { execFileSync } from 'node:child_process'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'

export const unwrapDefault = value => {
  let current = value
  while (current && typeof current !== 'function' && 'default' in current) {
    current = current.default
  }
  return current
}

export const parseArgs = argv => new Map(
  argv.flatMap(arg => {
    const match = arg.match(/^--([^=]+)=(.*)$/)
    if (match) return [[match[1], match[2]]]
    const flag = arg.match(/^--(.+)$/)
    return flag ? [[flag[1], '1']] : []
  }),
)

export const getArg = (args, ...names) => {
  for (const name of names) {
    if (args.has(name)) return args.get(name)
  }
}

export function parseLimit(value, argName) {
  const normalized = String(value).trim().toLowerCase()
  if (['all', 'inf', 'infinite', 'infinity', 'unlimited'].includes(normalized)) return Infinity
  if (!/^\d+$/.test(normalized)) {
    throw new Error(`${argName} must be a non-negative integer or "all"`)
  }
  return Number.parseInt(normalized, 10)
}

export const formatLimit = value => Number.isFinite(value) ? value : 'all'

export const pathExists = filePath => fs.access(filePath)
  .then(() => true)
  .catch(() => false)

export function exec(command, commandArgs, cwd) {
  execFileSync(command, commandArgs, { cwd, stdio: 'inherit' })
}

export async function readDefaultReferenceRef(repoRoot) {
  const refFile = path.join(repoRoot, '.parity/REFERENCE_REF')
  try {
    const contents = await fs.readFile(refFile, 'utf8')
    const ref = contents.trim().split('\n').find(line => line && !line.startsWith('#'))
    if (ref) return ref
  } catch {
    // file missing or unreadable; fall through
  }
  return 'main'
}

export async function ensureReferenceAPI({
  args,
  repoRoot,
  referenceRoot,
  referenceBinariesDirPath,
}) {
  const referenceRef = args.get('reference-ref') ?? await readDefaultReferenceRef(repoRoot)
  const bundlePath = path.join(referenceRoot, '.parity-platform-api.compiled.mjs')
  if (!await pathExists(path.join(referenceRoot, 'package.json'))) {
    await fs.mkdir(path.dirname(referenceRoot), { recursive: true })
    exec('git', ['worktree', 'add', '--detach', referenceRoot, referenceRef], repoRoot)
  }
  if (!args.has('skip-reference-rebuild') || args.has('rebuild-reference') || !await pathExists(bundlePath)) {
    const binariesDirPathLiteral = JSON.stringify(referenceBinariesDirPath)
    const buildBanner = `globalThis.texts={IS_DEV:true,isLoggingEnabled:false,log(){},error(){},constants:{USER_AGENT:'platform-imessage-parity',APP_VERSION:'1.0.0'},Sentry:{captureException(){},captureMessage(){},startTransaction(){}},async trackPlatformEvent(){},getBinariesDirPath(){return ${binariesDirPathLiteral}},fetch:globalThis.fetch,fetchStream:undefined,createHttpClient:undefined,nativeFetch:undefined,nativeFetchStream:undefined,runWorker:undefined,forkChildProcess:undefined,getOriginalObject:undefined,openBrowserWindow:undefined};`
    exec('yarn', [], referenceRoot)
    exec('bun', ['build:swift', '--standalone'], referenceRoot)
    exec('bun', [
      'build',
      'src/api.ts',
      '--target=node',
      '--format=esm',
      '--external',
      'electron',
      '--external',
      '@textshq/platform-test-lib',
      '--banner',
      buildBanner,
      '--outfile',
      bundlePath,
    ], referenceRoot)
  }
  return bundlePath
}
