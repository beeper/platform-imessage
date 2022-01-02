import { texts } from '@textshq/platform-sdk'

import * as bplistParser from './bplist-parser'

const BPLIST_MAGIC = Buffer.from('bplist')

export default function safeBplistParse(_buffer: ArrayBufferLike | Buffer) {
  const buffer = 'equals' in _buffer ? _buffer : Buffer.from(_buffer)
  const first6 = buffer.slice(0, 6)
  if (!first6.equals(BPLIST_MAGIC)) {
    if (texts.IS_DEV) console.log('expected bplist, found', first6.toString())
    // if (IS_DEV) fs.writeFileSync(os.homedir() + '/Downloads/imsg/' + msgID + '-unknown.bin', payloadBuffer)
    return
  }
  return bplistParser.parseBuffer(buffer)
}
