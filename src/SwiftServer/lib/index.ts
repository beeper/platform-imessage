import path from 'path'

import { BINARIES_DIR_PATH } from '../../constants'

declare const __non_webpack_require__: NodeRequire
const actualRequire = typeof __non_webpack_require__ === 'undefined' ? require : __non_webpack_require__

const { decodeAttributedString: _decodeAttributedString } = actualRequire(path.join(BINARIES_DIR_PATH, `swift_${process.arch}.node`))

interface Attribute {
  'key': string
  'value': string
  'from': number
  'to': number
}

export const decodeAttributedString: ((data: Buffer) => (Attribute[] | undefined)) = _decodeAttributedString
