import { isEmojiOrSpacesOnlyString } from '@textshq/platform-sdk/dist/emoji'
import { BeeperMessage } from './desktop-types'

// Keep in sync with Message.Part.isSelectable in src/IMessage/Sources/IMDatabase/Database/IMDatabase+Closest.swift
export const isSelectable = (message: BeeperMessage): boolean =>
  (!message.attachments?.length
    && !message.links?.length
    && !message.tweets?.length
    && message.text != null
    && !isEmojiOrSpacesOnlyString(message.text))
