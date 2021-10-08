// linter doesn't know that this file is compile-time-only
// eslint-disable-next-line import/no-extraneous-dependencies
import { clean, build, Config } from 'node-swift'
import { promises as fsPromises } from 'fs'
import { shellExec } from '../util'

async function isRosetta(): Promise<boolean> {
  return (await shellExec('sysctl', '-in', 'sysctl.proc_translated')) === '1\n'
}

(async () => {
  const buildOptions: Config = {
    packagePath: 'src/SwiftServer',
    macVersion: '10.11',
    static: true,
    swiftFlags: '',
  }

  const config = (process.argv.includes('--debug') || process.env.NODE_ENV === 'development') ? 'debug' : 'release'

  if (process.argv.includes('--no-spaces')) {
    buildOptions.swiftFlags += '-DNO_SPACES'
  }

  if (config === 'release') await clean()

  async function buildTriple(triple: string, arch: string) {
    console.log(`Building SwiftServer for ${triple}...`)

    const binaryPath = await build(config, {
      ...buildOptions,
      triple,
    })

    const dest = `binaries/swift_${arch}.node`
    if (config === 'release') {
      await shellExec('strip', '-ur', binaryPath, '-o', dest)
    } else {
      await fsPromises.copyFile(binaryPath, dest)
    }
  }

  await buildTriple('x86_64-apple-macosx', 'x64')
  if (config === 'release' || process.arch === 'arm64' || await isRosetta()) {
    await buildTriple('arm64-apple-macosx', 'arm64')
  }
})()
