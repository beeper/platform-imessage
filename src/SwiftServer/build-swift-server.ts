// linter doesn't know that this file is compile-time-only
// eslint-disable-next-line import/no-extraneous-dependencies
import { clean, build } from 'node-swift'
import { promises as fsPromises } from 'fs';

(async () => {
  const buildOptions = {
    packagePath: 'src/SwiftServer',
    macVersion: '10.11',
  }

  const config = (process.argv.includes('--debug') || process.env.NODE_ENV === 'development') ? 'debug' : 'release'

  // await clean();

  async function buildTriple(triple: string, arch: string) {
    console.log(`Building SwiftServer for ${triple}...`)

    const binaryPath = await build(config, {
      ...buildOptions,
      triple,
    })

    await fsPromises.copyFile(
      binaryPath,
      `binaries/swift_${arch}.node`,
    )
  }

  await buildTriple('x86_64-apple-macosx', 'x64')
  await buildTriple('arm64-apple-macosx', 'arm64')
})()
