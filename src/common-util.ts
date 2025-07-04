import { isEmojiOrSpacesOnlyString } from '@textshq/platform-sdk/dist/emoji'
import { BeeperMessage } from './beeper-platform-sdk'

export const isSelectable = (message: BeeperMessage): boolean =>
  (!message.attachments?.length
    && !message.links?.length
    && !message.tweets?.length
    && typeof message.extra?.part === 'undefined'
    && message.text != null
    && !isEmojiOrSpacesOnlyString(message.text))
