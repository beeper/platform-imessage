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

export const ASSOC_MSG_TYPE = {
  1000: 'sticker',

  2000: 'heart',
  2001: 'like',
  2002: 'dislike',
  2003: 'laugh',
  2004: 'emphasize',
  2005: 'question',

  3000: 'heart',
  3001: 'like',
  3002: 'dislike',
  3003: 'laugh',
  3004: 'emphasize',
  3005: 'question',
}

export const EXPRESSIVE_MSGS = {
  'com.apple.messages.effect.CKEchoEffect': 'Echo screen',
  'com.apple.messages.effect.CKSpotlightEffect': 'Spotlight screen',
  'com.apple.messages.effect.CKHappyBirthdayEffect': 'Balloons screen',
  'com.apple.messages.effect.CKConfettiEffect': 'Confetti screen',
  'com.apple.messages.effect.CKHeartEffect': 'Love screen',
  'com.apple.messages.effect.CKLasersEffect': 'Lasers screen',
  'com.apple.messages.effect.CKFireworksEffect': 'Fireworks screen',
  'com.apple.messages.effect.CKShootingStarEffect': 'Shooting Star screen',
  'com.apple.messages.effect.CKSparklesEffect': 'Celebration screen',
  'com.apple.MobileSMS.expressivesend.impact': 'Slam text',
  'com.apple.MobileSMS.expressivesend.loud': 'Loud text',
  'com.apple.MobileSMS.expressivesend.gentle': 'Gentle text',
  'com.apple.MobileSMS.expressivesend.invisibleink': 'Invisible Ink text',
}

export enum AttachmentTransferState {
  NOT_DOWNLOADED = 0,
  UNKNOWN_1 = 1,
  DOWNLOADING = 3,
  DOWNLOADED = 5,
  UNKNOWN_2 = 6,
}

export enum BalloonBundleID {
  URL = 'com.apple.messages.URLBalloonProvider',
  DIGITAL_TOUCH = 'com.apple.DigitalTouchBalloonProvider',
  HANDWRITING = 'com.apple.Handwriting.HandwritingProvider',
  BIZ_EXTENSION = 'com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.icloud.apps.messages.business.extension',
  APPLE_PAY = 'com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.PassbookUIService.PeerPaymentMessagesExtension',
}

export const MSG_EXTENSION_PREFIX = 'com.apple.messages.MSMessageExtensionBalloonPlugin'

const MACOS_MAJOR_VERSION = +os.release().split('.')[0]
export const IS_MOJAVE_OR_UP = MACOS_MAJOR_VERSION >= 18
export const IS_BIG_SUR_OR_UP = MACOS_MAJOR_VERSION >= 20
