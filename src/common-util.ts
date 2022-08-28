import { isEmojiOrSpacesOnlyString } from '@textshq/platform-sdk/dist/emoji'
import type { MessageWithExtra } from './mappers'

export const isSelectable = (message: MessageWithExtra) =>
  (!message.attachments?.length
    && !message.links?.length
    && !message.tweets?.length
    && typeof message.extra?.part === 'undefined'
    && !isEmojiOrSpacesOnlyString(message.text))
