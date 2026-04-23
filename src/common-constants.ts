// NOTE: DO NOT PREFIX THESE IMPORTS WITH `node:`, it doesn't bundle correctly
// on desktop
import os from 'os'
import path from 'path'
import url from 'url'
import { texts } from '@textshq/platform-sdk'
import type { SupportedReaction } from '@textshq/platform-sdk'

export const BINARIES_DIR_PATH = texts?.getBinariesDirPath('imessage')
  ?? path.join(process.cwd(), 'binaries')

export const supportedReactions = {
  heart: { title: 'Heart', render: '❤️' },
  like: { title: 'Like', render: '👍' },
  dislike: { title: 'Dislike', render: '👎' },
  laugh: { title: 'Laugh', render: 'HAHA', imgURL: url.pathToFileURL(path.join(BINARIES_DIR_PATH, 'haha.svg')).href },
  emphasize: { title: 'Emphasize', render: '‼️' },
  question: { title: 'Question', render: '❓' },
} as const satisfies Record<string, SupportedReaction>

const [DARWIN_MAJOR_VERSON, DARWIN_MINOR_VERSION] = os.release().split('.').map(Number)

export const MIN_MACOS_VERSION_ERROR = 'iMessage requires macOS Big Sur or later'
export const IS_BIG_SUR_OR_UP = DARWIN_MAJOR_VERSON >= 20
export const IS_MONTEREY_OR_UP = DARWIN_MAJOR_VERSON >= 21
export const IS_VENTURA_OR_UP = DARWIN_MAJOR_VERSON >= 22
export const IS_SONOMA_OR_UP = DARWIN_MAJOR_VERSON >= 23
export const IS_SEQUOIA_OR_UP = DARWIN_MAJOR_VERSON >= 24
export const IS_SEQUOIA_15_5_OR_UP = DARWIN_MAJOR_VERSON >= 24 && DARWIN_MINOR_VERSION >= 5
export const IS_TAHOE_OR_UP = DARWIN_MAJOR_VERSON >= 25
