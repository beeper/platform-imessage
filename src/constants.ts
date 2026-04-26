// NOTE: DO NOT PREFIX THESE IMPORTS WITH `node:`, it doesn't bundle correctly
// on desktop
import path from 'path'
import { BINARIES_DIR_PATH } from './common-constants'

export const APP_BUNDLE_ID = 'com.kishanbagaria.jack'

export const ARCH_BINARIES_DIR_PATH = path.join(BINARIES_DIR_PATH, `${process.platform}-${process.arch}`)
