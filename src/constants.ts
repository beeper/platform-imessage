import os from 'os'
import path from 'path'
import { texts, SupportedReaction } from '@textshq/platform-sdk'

export const supportedReactions: Record<string, SupportedReaction> = {
  heart: { title: 'Heart', render: '❤️' },
  like: { title: 'Like', render: '👍' },
  dislike: { title: 'Dislike', render: '👎' },
  laugh: { title: 'Laugh', render: '😂' },
  emphasize: { title: 'Emphasize', render: '‼️' },
  question: { title: 'Question', render: '❓' },
}

export const ASSOC_MSG_TYPE = {
  3: 'heading', // only seen used with apple watch replies like "completed a workout" or "closed all three Activity rings"

  1000: 'sticker',

  2000: 'reacted_heart',
  2001: 'reacted_like',
  2002: 'reacted_dislike',
  2003: 'reacted_laugh',
  2004: 'reacted_emphasize',
  2005: 'reacted_question',

  3000: 'unreacted_heart',
  3001: 'unreacted_like',
  3002: 'unreacted_dislike',
  3003: 'unreacted_laugh',
  3004: 'unreacted_emphasize',
  3005: 'unreacted_question',
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

export const RECEIVER_NAME_CONSTANT = '$(kIMTranscriptPluginBreadcrumbTextReceiverIdentifier)'
export const SENDER_NAME_CONSTANT = '$(kIMTranscriptPluginBreadcrumbTextSenderIdentifier)'

const [DARWIN_MAJOR_VERSON] = os.release().split('.').map(Number)
export const IS_MOJAVE_OR_UP = DARWIN_MAJOR_VERSON >= 18
export const IS_BIG_SUR_OR_UP = DARWIN_MAJOR_VERSON >= 20

export const CHAT_DB_PATH = path.join(os.homedir(), 'Library/Messages/chat.db')

export const BINARIES_DIR_PATH = texts.constants.BUILD_DIR_PATH + '/platform-imessage'
export const ARCH_BINARIES_DIR_PATH = path.join(BINARIES_DIR_PATH, `${process.platform}-${process.arch}`)

export const APP_BUNDLE_ID = 'com.kishanbagaria.jack'
