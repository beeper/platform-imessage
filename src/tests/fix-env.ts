// import '@textshq/platform-test-lib'
import path from 'path'
import type { texts as textsGlobal } from '@textshq/platform-sdk'

const BINARIES_DIR_PATH = path.join(__dirname, '../../binaries')
declare global {
  // eslint-disable-next-line no-var, vars-on-top
  var texts: typeof textsGlobal
}
globalThis.texts = { getBinariesDirPath: () => BINARIES_DIR_PATH } as unknown as typeof textsGlobal

jest.mock('../constants', () => ({
  ...jest.requireActual('../constants') as typeof import('../constants'),
  BINARIES_DIR_PATH,
}))
