import { CursorProp, MessageReaction, Paginated, Participant } from '@textshq/platform-sdk'
import swiftServer from './SwiftServer/lib'
import { likelyAlphanumericSenderID } from './heuristics'

interface Messagelike extends CursorProp {
  threadID?: string
  reactions?: MessageReaction[]
  senderID: string
}

interface Threadlike {
  id: string
  messages?: Paginated<Messagelike>
  participants: Paginated<Participant>
}

const { hashers } = swiftServer

export function hashParticipantID(id: string): string {
  if (likelyAlphanumericSenderID(id)) return id
  return hashers.participant.tokenizeRemembering(id)
}

export function originalThreadID(possiblyHash: string): string {
  if (!possiblyHash.startsWith('imsg')) return possiblyHash

  return hashers.thread.recoverOriginal(possiblyHash)
}

export function originalParticipantID(possiblyHash: string): string {
  // for unhashed participant IDs, just return as-is
  if (!possiblyHash.startsWith('imsg')) return possiblyHash

  return hashers.participant.recoverOriginal(possiblyHash)
}

export function hashReaction(reaction: MessageReaction): MessageReaction {
  return {
    ...reaction,
    // imessage doesn't support `allowsMultipleReactionsToSingleMessage`, so we
    // can just straightforwardly hash the id (participant id) here without
    // worrying about the concatenated form
    id: hashParticipantID(reaction.id),
    participantID: hashParticipantID(reaction.participantID),
  }
}

export function hashMessage<M extends Messagelike>(message: M): M {
  return ({
    ...message,
    threadID: message.threadID ? hashers.thread.tokenizeRemembering(message.threadID) : undefined,
    reactions: message.reactions ? message.reactions.map(hashReaction) : undefined,
    senderID: hashParticipantID(message.senderID),
  })
}

export function hashParticipant(participant: Participant): Participant {
  return {
    ...participant,
    id: hashParticipantID(participant.id),
  }
}

export function hashThreadID(id: string): string {
  return hashers.thread.tokenizeRemembering(id)
}

function hashPaginated<T extends CursorProp>(paginated: Paginated<T>, hasher: (unhashed: T) => T): Paginated<T> {
  return {
    hasMore: paginated.hasMore,
    items: paginated.items.map(hasher),
  }
}

export function hashThread<T extends Threadlike>(thread: T): T {
  return ({
    ...thread,
    id: hashers.thread.tokenizeRemembering(thread.id),
    ...(thread.messages ? { messages: hashPaginated(thread.messages, hashMessage) } : {}),
    participants: hashPaginated(thread.participants, hashParticipant),
  })
}
