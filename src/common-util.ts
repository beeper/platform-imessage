import type { MessageWithExtra } from './mappers'

// todo handle emoji only messages
export const isSelectable = (message: MessageWithExtra) =>
  (!message.attachments?.length
    && !message.links?.length
    && !message.tweets?.length
    && typeof message.extra?.part === 'undefined')
