import { isEmojiOrSpacesOnlyString } from '@textshq/platform-sdk/dist/emoji'
import { BeeperMessage } from './desktop-types'

export const isSelectable = (message: BeeperMessage): boolean =>
  (!message.attachments?.length
    && !message.links?.length
    && !message.tweets?.length
    && message.text != null
    && !isEmojiOrSpacesOnlyString(message.text))
