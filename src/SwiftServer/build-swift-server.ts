// linter doesn't know that this file is compile-time-only
// eslint-disable-next-line import/no-extraneous-dependencies
import { clean, build, Config } from 'node-swift'
import { promises as fsp } from 'fs'
import { resolve } from 'path'
import { shellExec } from '../util'

async function isRosetta(): Promise<boolean> {
  return (await shellExec('sysctl', '-in', 'sysctl.proc_translated')) === '1\n'
}

const codesign = (filePath: string) => shellExec('codesign', '-fs', '-', filePath)

const dropboxIgnoreDir = (dirPath: string) =>
  shellExec('xattr', '-w', 'com.dropbox.ignored', '1', dirPath)

async function main() {
  const buildOptions: Config = {
    packagePath: 'src/SwiftServer',
    macVersion: '10.11',
    swiftFlags: '',
  }

  const config = (process.argv.includes('--debug') || process.env.NODE_ENV === 'development') ? 'debug' : 'release'

  if (process.argv.includes('--no-spaces')) {
    buildOptions.swiftFlags += '-DNO_SPACES'
  }

  if (config === 'release') {
    await clean()
    await dropboxIgnoreDir('build')
  }

  async function buildTriple(triple: string, arch: string) {
    console.log(`Building ${triple}...`)

    const binaryPath = await build(config, {
      ...buildOptions,
      triple,
    })

    const outdir = `binaries/${process.platform}-${arch}`
    fsp.mkdir(outdir, { recursive: true })
    const dest = `${outdir}/swift-server.node`
    if (config === 'release') {
      await shellExec('strip', '-ur', binaryPath, '-o', dest)
    } else {
      await fsp.copyFile(binaryPath, dest)
    }

    const libNodeAPIDest = `${outdir}/libNodeAPI.dylib`
    await fsp.copyFile(resolve(binaryPath, '../libNodeAPI.dylib'), libNodeAPIDest)

    await Promise.all([
      codesign(dest),
      codesign(libNodeAPIDest),
    ])
  }

  const onRosetta = await isRosetta()
  if (config === 'release' || onRosetta || process.arch === 'x64') {
    await buildTriple('x86_64-apple-macosx', 'x64')
  }
  if (config === 'release' || onRosetta || process.arch === 'arm64') {
    await buildTriple('arm64-apple-macosx', 'arm64')
  }
  await dropboxIgnoreDir('build')
}

main()
