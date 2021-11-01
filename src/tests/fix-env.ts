// import '@textshq/platform-test-lib'
import path from 'path'

globalThis.texts = { constants: { BUILD_DIR_PATH: path.join(__dirname, '../../') } }
jest.mock('../constants', () => ({
  ...jest.requireActual('../constants') as typeof import('../constants'),
  BINARIES_DIR_PATH: path.join(__dirname, '../../binaries'),
}))
