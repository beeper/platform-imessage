// linter doesn't know that this file is compile-time-only
// eslint-disable-next-line import/no-extraneous-dependencies
import { clean, build, Config } from 'node-swift'
import fs, { promises as fsp } from 'fs'
import path from 'path'
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
  shellExec('xattr', '-w', 'com.dropbox.ignored', '1', dirPath)

const strip = (src: string, dest?: string) =>
  shellExec('strip', ...(dest ? ['-ur', src, '-o', dest] : ['-ur', src]))

const ROOT_DIR_PATH = path.join(__dirname, '../..')
const BUILD_DIR_PATH = path.join(ROOT_DIR_PATH, 'build')
const PACKAGE_DIR_PATH = path.join(ROOT_DIR_PATH, 'src/SwiftServer')

const xcArchMap = {
  arm64: 'arm64',
  x64: 'x86_64',
}

const config = (process.argv.includes('--debug') || process.env.NODE_ENV === 'development') ? 'debug' : 'release'
const NO_SPACES = process.argv.includes('--no-spaces')
const USE_SWIFT_PM = process.argv.includes('--use-swiftpm') || process.argv.includes('--use-spm')

async function main() {
  async function buildForArch(arch?: string) {
    const buildOptions: Config = {
      // we isolate the build directory for arch and config because of this random error on subsequent builds if it's just isolated by config
      // [Error: ENOENT: no such file or directory, rename 'platform-imessage/build/debug/debug/libNodeSwiftHost.dylib' -> 'platform-imessage/build/debug/debug/SwiftServer.node']
      buildPath: path.join(BUILD_DIR_PATH, `${config}-${arch || 'universal'}`),
      packagePath: PACKAGE_DIR_PATH,
      swiftFlags: '',
    }

    if (config === 'release' || process.argv.includes('--clean')) await clean(buildOptions)
    await dropboxIgnoreDir(BUILD_DIR_PATH)

    console.log(`Building ${arch || 'universal'} target...`)

    if (NO_SPACES) buildOptions.swiftFlags += '-DNO_SPACES'

    const binaryPath = await build(config, {
      ...buildOptions,
      builder: USE_SWIFT_PM ? {} : {
        type: 'xcode',
        destinations: arch ? [`platform=macOS,arch=${xcArchMap[arch]}`] : undefined,
        settings: arch ? ['ONLY_ACTIVE_ARCH=YES'] : undefined,
      },
    })

    if (arch) {
      const outdir = path.join(ROOT_DIR_PATH, `binaries/${process.platform}-${arch}`)
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
        Object.keys(xcArchMap)
          .map(async _arch => {
            const outdir = path.join(ROOT_DIR_PATH, `binaries/${process.platform}-${_arch}`)
            await lipoThin(_arch, binaryPath, path.join(outdir, 'SwiftServer.node'))
            await strip(binaryPath, binaryPath)
          }),
      )
    }
  }

  if (config === 'release') {
    await buildForArch()
  } else {
    const onRosetta = await isRosetta()
    for (const arch of Object.keys(xcArchMap)) {
      if (onRosetta || process.arch === arch || process.argv.includes('--all-archs')) {
        await buildForArch(arch)
      }
    }
  }
  await dropboxIgnoreDir(BUILD_DIR_PATH)
}

main().catch(console.error)

if (process.argv.includes('--watch')) {
  console.log('Watching for changes...')
  let isBuilding = false
  const listener = (event: fs.WatchEventType, fileName: string) => {
    console.log('[fs watch event]', event, fileName, new Date().toLocaleString(), isBuilding ? '[existing build in progress]' : '')
    if (!isBuilding) {
      isBuilding = true
      main()
        .catch(console.error)
        .finally(() => { isBuilding = false })
    }
  }
  fs.watch(PACKAGE_DIR_PATH, { recursive: true }, listener)
}
