import { PlatformInfo, MessageDeletionMode, Attribute, Participant } from '@textshq/platform-sdk'
import { supportedReactions, IS_BIG_SUR_OR_UP, IS_MONTEREY_OR_UP, IS_VENTURA_OR_UP } from './common-constants'
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
<svg width="1em" height="1em" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
<rect width="16" height="16" rx="5" fill="#A7A7A7"/>
<path d="M12.1716 10.7198C12.0154 11.0809 11.8304 11.4132 11.616 11.7188C11.3239 12.1353 11.0847 12.4236 10.9004 12.5837C10.6146 12.8465 10.3084 12.9811 9.98054 12.9888C9.74517 12.9888 9.46131 12.9218 9.13089 12.7859C8.79939 12.6507 8.49475 12.5837 8.21619 12.5837C7.92404 12.5837 7.61072 12.6507 7.27558 12.7859C6.93993 12.9218 6.66954 12.9926 6.4628 12.9996C6.1484 13.013 5.83501 12.8746 5.5222 12.5837C5.32254 12.4096 5.07282 12.111 4.77365 11.6881C4.45268 11.2365 4.18879 10.7128 3.98205 10.1158C3.76065 9.47089 3.64966 8.84641 3.64966 8.24183C3.64966 7.54929 3.7993 6.95199 4.09904 6.45145C4.33461 6.0494 4.64799 5.73225 5.04022 5.49942C5.43245 5.2666 5.85625 5.14796 6.31265 5.14036C6.56237 5.14036 6.88986 5.21761 7.29682 5.36942C7.70264 5.52175 7.96321 5.599 8.07745 5.599C8.16286 5.599 8.45233 5.50867 8.94304 5.3286C9.40709 5.16161 9.79875 5.09246 10.1196 5.1197C10.989 5.18986 11.6422 5.53259 12.0766 6.15005C11.299 6.62119 10.9144 7.28107 10.922 8.12759C10.9291 8.78696 11.1683 9.33566 11.6384 9.77133C11.8514 9.97353 12.0893 10.1298 12.3541 10.2408C12.2967 10.4073 12.2361 10.5668 12.1716 10.7198ZM10.1776 2.87336C10.1776 3.39017 9.98883 3.87272 9.61249 4.31936C9.15832 4.85032 8.60899 5.15714 8.01328 5.10873C8.00569 5.04672 8.00129 4.98147 8.00129 4.9129C8.00129 4.41676 8.21727 3.88579 8.60082 3.45166C8.79231 3.23185 9.03585 3.04908 9.33119 2.90328C9.62588 2.75965 9.90463 2.68023 10.1668 2.66663C10.1745 2.73572 10.1776 2.80481 10.1776 2.87336V2.87336Z" fill="white"/>
</svg>
  `,
  loginMode: 'custom',
  deletionMode: MessageDeletionMode.UNSUPPORTED,
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
        // Attribute.SUPPORTS_EDIT_MESSAGE,
      ] : []
    ),
  ]),
  reactions: IS_BIG_SUR_OR_UP ? { supported: supportedReactions } : undefined,
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
      description: 'This will require the installation of a helper tool.',
      type: 'checkbox',
      default: false,
    },
  } : {},
  extra: {
    canQuote,
    canReact,
    requiresAccessibilityAccess: IS_BIG_SUR_OR_UP,
    requiresContactsAccess: true,
    canQuoteOriginalMessageOnly: true,
    knownIssues: [
      'Messages.app will be open in the background but Texts can keep it hidden.',
      ...[(() => {
        if (IS_MONTEREY_OR_UP) return "Reacting/replying to some types of messages isn't supported."
        if (IS_BIG_SUR_OR_UP) return "On macOS Big Sur, reacting/replying to non-text messages isn't supported. We recommend updating to the latest macOS."
        return "On macOS Catalina and lower: mark as read, typing indicator and reactions aren't supported. We recommend updating to the latest macOS."
      })()],
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
