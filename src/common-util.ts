import { isEmojiOrSpacesOnlyString } from '@textshq/platform-sdk/dist/emoji'
import type { MessageWithExtra } from './mappers'

export const isSelectable = (message: MessageWithExtra): boolean =>
  (!message.attachments?.length
    && !message.links?.length
    && !message.tweets?.length
    && typeof message.extra?.part === 'undefined'
    && message.text != null
    && !isEmojiOrSpacesOnlyString(message.text))
