// FIXME: The need for this declaration file will hopefully be resolved once
// this repo merges with beeper-desktop-new (i.e. we finally get around to
// monorepoification).

// Some kind of `import`/`export`/etc. is needed to make TypeScript consider
// this file to be a module, which avoids overwriting types which we merely
// wish to extend.
import type { Message, Thread, Paginated, Awaitable } from '@textshq/platform-sdk'

declare module '@textshq/platform-sdk' {
  // (2025-07-03) https://github.com/beeper/beeper-desktop-new/blob/8a605b41935215c0380063f71e30048c0efeb588/packages/@beeper/platform-sdk/src/Thread.ts#L49
  export interface ThreadReminder {
    remindAtMs?: number
    dismissOnIncomingMessage?: boolean
    /**
     * The timestamp corresponding to if and when the user was reminded
     */
    userRemindedAt?: number
  }

  export interface Thread {
    reminder?: ThreadReminder
  }

  export interface PlatformAPI {
    // (2025-07-03) https://github.com/beeper/beeper-desktop-new/blob/8a605b41935215c0380063f71e30048c0efeb588/packages/@beeper/platform-sdk/src/PlatformAPI.ts#L267
    setThreadReminder?: (roomID: string, reminder: ThreadReminder) => Awaitable<void>
    clearThreadReminder?: (roomID: string) => Awaitable<void>
    recordThreadReminderElapsed?: (roomID: string) => Awaitable<void>
  }
}

export type MessageContentType =
  'TEXT' | 'NOTICE' | 'IMAGE' | 'VIDEO' | 'VOICE' | 'AUDIO' | 'FILE' |
  'STICKER' | 'LOCATION' | 'MEMBERSHIP' | 'NAME' | 'STATE' | 'HIDDEN' | 'REACTION'

interface iMessageExtra {
  // `isSMS` is already available on `BeeperMessageExtra`
  part?: number
}

// (2025-07-04)
export interface BeeperMessageExtra extends iMessageExtra {
  // aka pendingMessageID
  echoID?: string
  // Points to the eventId containing the last edition of this message
  lastEditionID?: string | null
  // Store last edition order
  lastEditionOrder?: number
  // Store last edition timestamp
  lastEditionTimestamp?: number
  type?: MessageContentType
  editedType?: MessageContentType
  // LocalEchoId or MatrixId
  eventID?: string
  // Show 'Encrypted content'
  isE2EE?: boolean
  // set by platform-imessage
  isSMS?: true | undefined
  eventType?: string
  replyThreadID?: string | null
  lastDeletionID?: string | null
  shouldNotify?: boolean
  shouldPreview?: boolean
  countsAsUnread?: boolean
  partialReactionContent?: {
    description?: string
    relatedEventID?: string
  }
  // If the message is formatted in HTML, then this contains the sanitized
  // content.
  sanitizedFormattedBody?: string
  membershipType?: unknown /* MembershipChangeType */
  scheduled?: boolean
  ogMsgID?: string
  isStalled?: boolean
  location?: {
    latitude: number
    longitude: number
  }
  couldHaveOTP?: boolean
  actions?: unknown[] /* Button[] */
}

// (2025-07-04)
export interface BeeperThreadExtra {
  bridge?: unknown /* BridgeEventContent */
  /**
   * @deprecated use `bridge.protocol` instead
   */
  protocol?: string
  bridgeName?: string
  roomType?: string
  // {"type":"m.tag","room_id":"!2np3uKRNH4JD0VfqtguT:beeper.local","content":{"tags":{"m.lowpriority":{"fi.mau.double_puppet_source":"mautrix-twitter","order":0.5}}}}
  tags?: { [tag: string]: any }
  isArchivedUpto?: string | null
  isArchivedUpToOrder?: number | null
  /** @deprecated use {@link BeeperMessage.isMarkedUnread} */
  isMarkedUnread?: boolean
  markedUnreadUpdatedAt?: number
  lastNotifiableMessageHsOrder?: number
  replacementRoomID?: string | null // tombstone event
  isSMS?: true | undefined
}

// (2025-07-04)
export interface BeeperMessage extends Omit<Message, 'extra' | '_original' | 'sortKey' | 'threadID'> {
  extra?: BeeperMessageExtra
  sortKey: string | number
  threadID: string
  // NOTE: this is actually typed as `undefined`, but we need to set this for
  // now. eliminate the need for this since it's a defunct concept
  _original?: unknown
  isRetrying?: boolean
  eventID?: string
}

// (2025-07-04)
export interface BeeperThread extends Omit<Thread, 'extra' | 'partialLastMessage' | 'messages'> {
  messages: Paginated<BeeperMessage>
  isE2EE?: boolean
  unreadCount?: number
  unreadMentionsCount?: number
  title?: string
  extra?: BeeperThreadExtra
  partialLastMessage?: BeeperMessage
  isMarkedUnread: boolean
  lastReadMessageSortKey?: BeeperMessage['sortKey']
  powerLevels?: unknown /* PowerLevelsEventContent */
}
