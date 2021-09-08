import { clean, build } from 'node-swift'
import { promises as fsPromises } from 'fs';

(async () => {
  const buildOptions = {
    packagePath: 'src/SwiftServer',
  }

  const config = 'release'

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
