// linter doesn't know that this file is compile-time-only
// eslint-disable-next-line import/no-extraneous-dependencies
import { clean, build, Config } from 'node-swift'
import fs, { promises as fsp } from 'fs'
import path from 'path'
import { shellExec } from '../util'

async function isRosetta(): Promise<boolean> {
  return (await shellExec('sysctl', '-in', 'sysctl.proc_translated')) === '1\n'
}

const codesign = (filePath: string) => shellExec('codesign', '-fs', '-', filePath)

const dropboxIgnoreDir = (dirPath: string) =>
  shellExec('xattr', '-w', 'com.dropbox.ignored', '1', dirPath)

const ROOT_DIR_PATH = path.join(__dirname, '../..')
const BUILD_DIR_PATH = path.join(ROOT_DIR_PATH, 'build')
const PACKAGE_DIR_PATH = path.join(ROOT_DIR_PATH, 'src/SwiftServer')

async function main() {
  const config = (process.argv.includes('--debug') || process.env.NODE_ENV === 'development') ? 'debug' : 'release'

  async function buildTriple(triple: string, arch: string) {
    const buildOptions: Config = {
      // we isolate the build directory for arch and config because of this random error on subsequent builds if it's just isolated by config
      // [Error: ENOENT: no such file or directory, rename 'platform-imessage/build/debug/debug/libNodeSwiftHost.dylib' -> 'platform-imessage/build/debug/debug/SwiftServer.node']
      buildPath: path.join(BUILD_DIR_PATH, `${config}-${arch}`),
      packagePath: PACKAGE_DIR_PATH,
      swiftFlags: '',
    }

    if (config === 'release' || process.argv.includes('--clean')) await clean(buildOptions)
    await dropboxIgnoreDir(BUILD_DIR_PATH)

    console.log(`Building ${triple}...`)

    if (process.argv.includes('--no-spaces')) {
      buildOptions.swiftFlags += '-DNO_SPACES'
    }

    const binaryPath = await build(config, {
      ...buildOptions,
      triple,
    })

    const outdir = path.join(ROOT_DIR_PATH, `binaries/${process.platform}-${arch}`)
    fsp.mkdir(outdir, { recursive: true })
    const dest = `${outdir}/swift.node`
    if (config === 'release') {
      await shellExec('strip', '-ur', binaryPath, '-o', dest)
    } else {
      await fsp.copyFile(binaryPath, dest)
    }

    const libNodeAPIDest = `${outdir}/libNodeAPI.dylib`
    await fsp.copyFile(path.join(binaryPath, '../libNodeAPI.dylib'), libNodeAPIDest)

    await Promise.all([
      codesign(dest),
      codesign(libNodeAPIDest),
    ])
  }

  const onRosetta = await isRosetta()
  for (const [arch, triple] of Object.entries({ arm64: 'arm64-apple-macosx', x64: 'x86_64-apple-macosx' })) {
    if (config === 'release' || onRosetta || process.arch === arch || process.argv.includes('--all-archs')) {
      await buildTriple(triple, arch)
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
