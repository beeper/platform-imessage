import os from 'os'
import type { SupportedReaction } from '@textshq/platform-sdk'

export const supportedReactions: Record<string, SupportedReaction> = {
  heart: { title: 'Heart', render: '❤️' },
  like: { title: 'Like', render: '👍' },
  dislike: { title: 'Dislike', render: '👎' },
  laugh: { title: 'Laugh', render: '😂' },
  emphasize: { title: 'Emphasize', render: '‼️' },
  question: { title: 'Question', render: '❓' },
}

const [DARWIN_MAJOR_VERSON] = os.release().split('.').map(Number)
export const IS_MOJAVE_OR_UP = DARWIN_MAJOR_VERSON >= 18
export const IS_CATALINA_OR_UP = DARWIN_MAJOR_VERSON >= 19
export const IS_BIG_SUR_OR_UP = DARWIN_MAJOR_VERSON >= 20
export const IS_MONTEREY_OR_UP = DARWIN_MAJOR_VERSON >= 21
export const IS_VENTURA_OR_UP = DARWIN_MAJOR_VERSON >= 22
