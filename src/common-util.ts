import { isEmojiOrSpacesOnlyString } from '@textshq/platform-sdk/dist/emoji'
import { BeeperMessage } from './desktop-types'

// Mirrors Swift's Message.Part.isSelectable (IMDatabase+Closest.swift): real,
// non-attachment, non-emoji text. Not line-for-line — TS also excludes links/tweets.
export const isSelectable = (message: BeeperMessage): boolean =>
  (!message.attachments?.length
    && !message.links?.length
    && !message.tweets?.length
    && message.text != null
    && !isEmojiOrSpacesOnlyString(message.text))

// OS-parameterized so the reply/react truth table is unit-testable. undefined = "always
// allowed" (Beeper Desktop's sentinel). Keep consistent with resolveMessageCell.
export const canQuoteMessage = (isMontereyOrUp: boolean): ((message: BeeperMessage) => boolean) | undefined =>
  (isMontereyOrUp ? undefined : isSelectable)

export const canReactMessage = (isMontereyOrUp: boolean): (message: BeeperMessage) => boolean =>
  (isMontereyOrUp
    ? (message: BeeperMessage) => !message.linkedMessageID || isSelectable(message)
    : isSelectable)
