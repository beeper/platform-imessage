import { texts } from '@textshq/platform-sdk'

import * as bplistParser from './bplist-parser'

const BPLIST_MAGIC = 'bplist'

export default function safeBplistParse(buffer: Buffer) {
  const first6 = buffer.toString('utf8', 0, 6)
  if (first6 !== BPLIST_MAGIC) {
    if (texts.IS_DEV) console.log('expected bplist, found', first6)
    // if (IS_DEV) fs.writeFileSync(os.homedir() + '/Downloads/imsg/' + msgID + '-unknown.bin', payloadBuffer)
    return
  }
  return bplistParser.parseBuffer(buffer)
}
