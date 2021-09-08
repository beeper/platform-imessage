import fs from 'fs/promises'
import { decodeAttributedString } from './lib/index'

(async () => {
  const buf = await fs.readFile(process.argv[2])
  console.log(decodeAttributedString(buf))
})()
