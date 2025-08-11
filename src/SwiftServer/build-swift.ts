// linter doesn't know that this file is compile-time-only
// eslint-disable-next-line import/no-extraneous-dependencies
import { clean, build, Config } from 'node-swift'
import fs, { promises as fsp } from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { shellExec } from '../util'

async function isRosetta(): Promise<boolean> {
  return (await shellExec('sysctl', '-in', 'sysctl.proc_translated')) === '1\n'
}

const lipoThin = (_arch: string, srcPath: string, destPath: string) => {
  const arch = _arch === 'x64' ? 'x86_64' : _arch
  return shellExec('/usr/bin/lipo', srcPath, '-thin', arch, '-output', destPath)
}

// const codesign = (filePath: string) =>
//   shellExec('codesign', '-fs', '-', filePath)

const dropboxIgnoreDir = (dirPath: string) =>
  shellExec('xattr', '-w', 'com.dropbox.ignored', '1', dirPath).catch(error => console.error('swallowing xattr failure:', error))

const strip = async (src: string, dest?: string) => {
  console.log(`build-swift: stripping ${src} -> ${dest}`)
  await shellExec('strip', ...(dest ? ['-ur', src, '-o', dest] : ['-ur', src]))
}

const uploadDebugFilesToSentry = async (searchPath: string): Promise<void> => {
  const token = process.env.SENTRY_AUTH_TOKEN
  if (!token) {
    throw new Error(`can't upload from ${searchPath} to sentry, missing SENTRY_AUTH_TOKEN env var`)
  }
  console.log('invoking sentry-cli to upload debug files from:', searchPath)
  const baseSentryCliArgs = [
    '--log-level', 'debug',
    '--org', 'a8c',
    '--project', 'beeper-desktop-new',
    '--auth-token', token,
  ]
  await shellExec('yarn', ...['sentry-cli', 'debug-files', 'upload', ...baseSentryCliArgs, searchPath])
}

const dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT_DIR_PATH = path.join(dirname, '../..')
const BUILD_DIR_PATH = path.join(ROOT_DIR_PATH, 'build')
const PACKAGE_DIR_PATH = path.join(ROOT_DIR_PATH, 'src/SwiftServer')

const xcArchMap = {
  arm64: 'arm64',
  x64: 'x86_64',
}
const allArches = Object.keys(xcArchMap) as unknown as [keyof typeof xcArchMap]

const config = (process.argv.includes('--debug') || process.env.NODE_ENV === 'development') ? 'debug' : 'release'
const NO_SPACES = process.argv.includes('--no-spaces')
const USE_SWIFT_PM = process.argv.includes('--use-swiftpm') || process.argv.includes('--use-spm')

async function main() {
  async function buildForArch(specificArch?: keyof typeof xcArchMap) {
    const buildOptions: Config = {
      // we isolate the build directory for arch and config because of this random error on subsequent builds if it's just isolated by config
      // [Error: ENOENT: no such file or directory, rename 'platform-imessage/build/debug/debug/libNodeSwiftHost.dylib' -> 'platform-imessage/build/debug/debug/SwiftServer.node']
      buildPath: path.join(BUILD_DIR_PATH, `${config}-${specificArch || 'universal'}`),
      packagePath: PACKAGE_DIR_PATH,
      swiftFlags: '',
    }

    if (config === 'release' || process.argv.includes('--clean')) await clean(buildOptions)
    await dropboxIgnoreDir(BUILD_DIR_PATH)

    console.log(`build-swift: building ${specificArch || 'universal'} target...`)

    if (NO_SPACES) buildOptions.swiftFlags += '-DNO_SPACES'

    // forcefully disable stripping, we can do it manually and we'd like to
    // upload symbols to sentry
    const xcodeBuilderSettings = [
      ...(specificArch ? ['ONLY_ACTIVE_ARCH=YES'] : []),
      'DEPLOYMENT_POSTPROCESSING=NO',
      'COPY_PHASE_STRIP=NO',
      'STRIP_STYLE=non-global',
      'STRIP_INSTALLED_PRODUCT=NO',
    ]
    const binaryPath = await build(config, {
      ...buildOptions,
      builder: USE_SWIFT_PM ? {} : {
        type: 'xcode',
        destinations: specificArch ? [`platform=macOS,arch=${xcArchMap[specificArch]}`] : undefined,
        settings: xcodeBuilderSettings,
      },
    })

    if (process.env.CI_PUBLISHING === 'true') {
      await uploadDebugFilesToSentry(binaryPath)
      await uploadDebugFilesToSentry(BUILD_DIR_PATH)
    }

    if (specificArch) {
      const outdir = path.join(ROOT_DIR_PATH, `binaries/${process.platform}-${specificArch}`)
      fsp.mkdir(outdir, { recursive: true })
      const dest = `${outdir}/SwiftServer.node`
      if (config === 'release') {
        await strip(binaryPath, dest)
      } else {
        await fsp.copyFile(binaryPath, dest)
      }
      // await codesign(dest)
    } else {
      await Promise.all(
        allArches
          .map(async arch => {
            const archOutDir = path.join(ROOT_DIR_PATH, `binaries/${process.platform}-${arch}`)
            console.log(`build-swift: thinning for ${arch}, outputting to ${archOutDir}`)
            await lipoThin(arch, binaryPath, path.join(archOutDir, 'SwiftServer.node'))
            await strip(binaryPath, binaryPath)
          }),
      )
    }
  }

  if (config === 'release') {
    await buildForArch()
  } else {
    const onRosetta = await isRosetta()
    for (const arch of allArches) {
      if (onRosetta || process.arch === arch || process.argv.includes('--all-archs')) {
        await buildForArch(arch)
      }
    }
  }
  await dropboxIgnoreDir(BUILD_DIR_PATH)
}

main().catch(error => {
  console.error('Failed to build Swift code:', error)
  process.exit(1)
})

if (process.argv.includes('--watch')) {
  console.log('build-swift: watching for changes...')
  let isBuilding = false
  const listener = (event: fs.WatchEventType, fileName: string | null) => {
    console.log('build-swift: fs watch event:', event, fileName, new Date().toLocaleString(), isBuilding ? '[existing build in progress]' : '')
    if (!isBuilding) {
      isBuilding = true
      main()
        .catch(console.error)
        .finally(() => { isBuilding = false })
    }
  }
  fs.watch(PACKAGE_DIR_PATH, { encoding: 'utf-8', recursive: true }, listener)
}
