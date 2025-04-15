import { PlatformInfo, MessageDeletionMode, Attribute, Participant } from '@textshq/platform-sdk'
import { supportedReactions, IS_BIG_SUR_OR_UP, IS_MONTEREY_OR_UP, IS_VENTURA_OR_UP, IS_SEQUOIA_OR_UP } from './common-constants'
import { isSelectable } from './common-util'
import type { MessageWithExtra } from './mappers'

const canQuote = !IS_MONTEREY_OR_UP ? isSelectable : (message: MessageWithExtra) => !message.extra?.part
const canReact = !IS_MONTEREY_OR_UP ? isSelectable : (message: MessageWithExtra) => !message.extra?.part && (message.linkedMessageID ? isSelectable(message) : true)

const info: PlatformInfo = {
  name: 'imessage',
  version: '1.0.0',
  displayName: 'iMessage',
  tags: IS_BIG_SUR_OR_UP ? [] : ['Beta'],
  icon: `
<svg width="20" height="18" viewBox="0 0 20 18" fill="none" xmlns="http://www.w3.org/2000/svg">
<path d="M9.99995 0.892499C4.76618 0.892499 0.523438 4.26842 0.523438 8.43459C0.527791 11.0813 2.2748 13.531 5.12747 14.8925C4.75456 15.6911 4.19448 16.4397 3.47043 17.108C4.87355 16.8723 6.19107 16.3787 7.3185 15.6633C8.1891 15.8685 9.09162 15.9739 9.99995 15.9753C15.2337 15.9753 19.4764 12.5994 19.4764 8.4332C19.4764 4.26842 15.2337 0.891113 9.99995 0.891113V0.892499Z" fill="white"/>
</svg>
  `,
  // @ts-expect-error - `brand` is valid, but we cannot update `platform-sdk`. See PLT-1246
  brand: {
    iconBackground: '#19BA3B',
    iconName: 'imessage',
  },
  loginMode: 'custom',
  deletionMode: IS_VENTURA_OR_UP ? MessageDeletionMode.UNSEND : MessageDeletionMode.UNSUPPORTED,
  editMessageTimeLimit: 15 * 60,
  // typingDurationMs: 3000,
  attributes: new Set([
    Attribute.CAN_MESSAGE_PHONE_NUMBER,
    Attribute.CAN_MESSAGE_EMAIL,
    Attribute.SUPPORTS_SEARCH,
    Attribute.NO_SUPPORT_GROUP_TITLE_CHANGE,
    Attribute.NO_SUPPORT_GROUP_ADD_PARTICIPANT,
    Attribute.NO_SUPPORT_GROUP_REMOVE_PARTICIPANT,
    Attribute.NO_SUPPORT_DUPLICATE_GROUP_CREATION,
    Attribute.SORT_MESSAGES_ON_PUSH,
    Attribute.GET_MESSAGES_SUPPORTS_AFTER_DIRECTION,
    ...(IS_BIG_SUR_OR_UP
      ? [
        Attribute.SUBSCRIBE_TO_THREAD_SELECTION,
        Attribute.SUPPORTS_STOP_TYPING_INDICATOR,
        Attribute.SINGLE_THREAD_CREATION_REQUIRES_MESSAGE,
        Attribute.GROUP_THREAD_CREATION_REQUIRES_MESSAGE,
        Attribute.SUPPORTS_QUOTED_MESSAGES,
        Attribute.SUPPORTS_DELETE_THREAD,
      ] : [
        Attribute.NO_SUPPORT_TYPING_INDICATOR,
      ]),
    ...(IS_VENTURA_OR_UP
      ? [
        Attribute.SUPPORTS_MARK_AS_UNREAD,
        // only for messages < 15 mins old
        Attribute.SUPPORTS_EDIT_MESSAGE,
      ].filter(Boolean) : []
    ),
  ]),
  reactions: IS_SEQUOIA_OR_UP ? { supported: supportedReactions, canReactWithAllEmojis: true } : IS_BIG_SUR_OR_UP ? { supported: supportedReactions } : undefined,
  attachments: {
    gifMimeType: 'image/gif',
    maxSize: {
      /*
        100 MB as of macOS Monterey 12.2
        Big media files are automatically compressed
      */
      files: 100 * 1024 * 1024,
    },
  },
  prefs: IS_BIG_SUR_OR_UP ? {
    hide_messages_app: {
      label: 'Hide Messages.app in Dock',
      description: 'This will prompt the installation of a helper tool.',
      type: 'checkbox',
      default: false,
    },
  } : {},
  extra: {
    e2ee: 'full',
    canQuote,
    canReact,
    requiresAccessibilityAccess: IS_BIG_SUR_OR_UP,
    requiresContactsAccess: true,
    canQuoteOriginalMessageOnly: true,
    knownIssues: [
      'Messages.app will be open in the background but Beeper can keep it hidden.',
      ...[(() => {
        if (IS_MONTEREY_OR_UP) return "Reacting/replying to some types of messages isn't supported."
        if (IS_BIG_SUR_OR_UP) return "On macOS Big Sur, reacting/replying to non-text messages isn't supported. We recommend updating to the latest macOS."
        return "On macOS Catalina and lower: mark as read, typing indicator and reactions aren't supported. We recommend updating to the latest macOS."
      })()],
      'Your iMessage chats won\'t be synced to your other devices.',
    ],
    getUnknownParticipant(participantID: string): Participant | undefined {
      if (!participantID) return
      if (participantID.includes('@')) return { id: participantID, email: participantID }
      return { id: participantID, phoneNumber: participantID }
    },
  },
  getUserProfileLink: ({ email, phoneNumber }) =>
    `imessage://${email || phoneNumber}`,
}

export default info
