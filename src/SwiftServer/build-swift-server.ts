// linter doesn't know that this file is compile-time-only
// eslint-disable-next-line import/no-extraneous-dependencies
import { clean, build, Config } from 'node-swift'
import { promises as fsPromises } from 'fs'
import { resolve } from 'path'
import { shellExec } from '../util'

async function isRosetta(): Promise<boolean> {
  return (await shellExec('sysctl', '-in', 'sysctl.proc_translated')) === '1\n'
}

(async () => {
  const buildOptions: Config = {
    packagePath: 'src/SwiftServer',
    macVersion: '10.11',
    swiftFlags: '',
  }

  const config = (process.argv.includes('--debug') || process.env.NODE_ENV === 'development') ? 'debug' : 'release'

  if (process.argv.includes('--no-spaces')) {
    buildOptions.swiftFlags += '-DNO_SPACES'
  }

  if (config === 'release') await clean()

  async function buildTriple(triple: string, arch: string) {
    console.log(`Building ${triple}...`)

    const binaryPath = await build(config, {
      ...buildOptions,
      triple,
    })

    const outdir = `binaries/${process.platform}-${arch}`
    fsPromises.mkdir(outdir, { recursive: true })
    const dest = `${outdir}/swift-server.node`
    if (config === 'release') {
      await shellExec('strip', '-ur', binaryPath, '-o', dest)
    } else {
      await fsPromises.copyFile(binaryPath, dest)
    }

    await fsPromises.copyFile(resolve(binaryPath, '../libNodeAPI.dylib'), `${outdir}/libNodeAPI.dylib`)
  }

  const onRosetta = await isRosetta()
  if (config === 'release' || onRosetta || process.arch === 'x64') {
    await buildTriple('x86_64-apple-macosx', 'x64')
  }
  if (config === 'release' || onRosetta || process.arch === 'arm64') {
    await buildTriple('arm64-apple-macosx', 'arm64')
  }
})()
