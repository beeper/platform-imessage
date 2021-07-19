const fs = require('fs').promises
const path = require('path')

const dirPath = process.argv[2]
const echoBigSur = process.argv[3]

const pathExists = fp =>
  fs.access(fp)
    .then(() => true)
    .catch(() => false)

async function main() {
  const files = await fs.readdir(dirPath)
  const out = {}
  // to keep order intact
  files.map(fileName => {
    const { name, ext } = path.parse(fileName)
    if (!['.applescript', '.js'].includes(ext)) return
    out[name] = []
  })
  await Promise.all(files.map(async fileName => {
    const { base, name, ext } = path.parse(fileName)
    if (!out[name]) return
    const filePath = path.join(dirPath, fileName)
    const bigSurOverridePath = path.join(dirPath, 'bigsur', base)
    const hasBigSurOverride = await pathExists(bigSurOverridePath)
    const source = await fs.readFile(hasBigSurOverride && echoBigSur ? bigSurOverridePath : filePath, 'utf-8')
    out[name] = [
      ext === '.js' ? 'JavaScript' : 'AppleScript',
      ext === '.js' ? `ObjC.import('stdlib')
var fn = (${source})
var args = \${0}
var out  = fn.apply(null, args)` : source,
    ]
  }))
  const json = JSON.stringify(out)
  console.log(Buffer.from(json).toString('base64'))
}
main()
