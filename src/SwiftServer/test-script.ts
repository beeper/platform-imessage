import fs from 'fs/promises'
import swiftServer from './lib/index'

(async () => {
  const buf = await fs.readFile(process.argv[2])
  console.log(swiftServer.decodeAttributedString(buf))
})()
