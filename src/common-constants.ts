// NOTE: DO NOT PREFIX THESE IMPORTS WITH `node:`, it doesn't bundle correctly on desktop
import os from 'os'
import path from 'path'
import url from 'url'
import { texts } from '@textshq/platform-sdk'
import type { SupportedReaction } from '@textshq/platform-sdk'

export const BINARIES_DIR_PATH = texts?.getBinariesDirPath('imessage')
  ?? path.join(process.cwd(), 'binaries')

const tapbackGraphicURL = (fileName: string) =>
  url.pathToFileURL(path.join(BINARIES_DIR_PATH, fileName)).href

export const supportedReactions = {
  heart: { title: 'Heart', render: '❤️', imgURL: tapbackGraphicURL('heart.svg') },
  like: { title: 'Like', render: '👍', imgURL: tapbackGraphicURL('thumbsUp.svg') },
  dislike: { title: 'Dislike', render: '👎', imgURL: tapbackGraphicURL('thumbsDown.svg') },
  laugh: { title: 'Laugh', render: 'HAHA', imgURL: tapbackGraphicURL('haha.svg') },
  emphasize: { title: 'Emphasize', render: '‼️', imgURL: tapbackGraphicURL('exclamation.svg') },
  question: { title: 'Question', render: '❓', imgURL: tapbackGraphicURL('question.svg') },
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
