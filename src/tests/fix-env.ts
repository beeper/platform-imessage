// import '@textshq/platform-test-lib'
import path from 'path'

const BINARIES_DIR_PATH = path.join(__dirname, '../../binaries')
globalThis.texts = { getBinariesDirPath: () => BINARIES_DIR_PATH }

jest.mock('../constants', () => ({
  ...jest.requireActual('../constants') as typeof import('../constants'),
  BINARIES_DIR_PATH,
}))
