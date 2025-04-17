import { CursorProp, Message, MessageReaction, Paginated, Participant, Thread } from '@textshq/platform-sdk'
import { threadHasher as globalThreadIDHasher, participantHasher as globalParticipantIDHasher } from './RustServer/lib'

export function hashParticipantID(id: string): string {
  return globalParticipantIDHasher.hashAndRemember(id)
}

export function originalParticipantID(possiblyHash: string): string {
  // for unhashed participant IDs, just return as-is
  if (!possiblyHash.startsWith('imsg')) return possiblyHash

  return globalParticipantIDHasher.originalFromHash(possiblyHash)
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

export function hashMessage(message: Message): Message {
  return ({
    ...message,
    threadID: message.threadID ? globalThreadIDHasher.hashAndRemember(message.threadID) : undefined,
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
  return globalThreadIDHasher.hashAndRemember(id)
}

function hashPaginated<T extends CursorProp>(paginated: Paginated<T>, hasher: (unhashed: T) => T): Paginated<T> {
  return {
    hasMore: paginated.hasMore,
    items: paginated.items.map(hasher),
  }
}

export function hashThread(thread: Thread): Thread {
  return ({
    ...thread,
    id: globalThreadIDHasher.hashAndRemember(thread.id),
    messages: hashPaginated(thread.messages, hashMessage),
    participants: hashPaginated(thread.participants, hashParticipant),
  })
}
