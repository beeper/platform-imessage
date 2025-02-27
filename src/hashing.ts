import type { Message, MessageReaction, Participant, Thread } from '@textshq/platform-sdk'
import * as crypto from 'node:crypto'

// NOTE(skip): doesn't provide real type safety, just improves readability in
// this file
type PII = string
type Hashed = string

export class HasherError extends Error {}

export class Hasher {
  private algorithm = 'sha512'

  private originals = new Map<Hashed, PII>()

  private cache = new Map<PII, Hashed>()

  // NOTE(skip): not a secret; merely used so that we aren't just hashing the
  // PII and nothing else
  #flavor = '50884d99c97714e59ad1a8147a145b5ef5528e40cba846de595af3f043327904'

  constructor(public readonly type: string) {
  }

  originalFromHash(hash: Hashed): PII {
    const threadID = this.originals.get(hash)
    if (!threadID) {
      throw new HasherError(`unknown hashed thread id ${hash} (currently remembered: ${this.originals.size})`)
    }
    return threadID
  }

  hashAndRemember(pii: PII): Hashed {
    if (this.cache.has(pii)) {
      return this.cache.get(pii)
    }

    const beingHashed = `${this.type}_${this.#flavor}_${pii}`
    const hashed = `imsg##${this.type}:` + crypto.hash(this.algorithm, beingHashed, 'hex')

    if (this.originals.has(hashed) && this.originals.get(hashed) !== pii) {
      throw new Error('thread id hasher collision') // rare
    }

    this.cache.set(pii, hashed)
    this.originals.set(hashed, pii)

    return hashed
  }
}

const globalThreadIDHasher = new Hasher('thread')
export const globalParticipantIDHasher = new Hasher('participant')

export function hashReaction(reaction: MessageReaction): MessageReaction {
  return {
    ...reaction,
    participantID: globalParticipantIDHasher.hashAndRemember(reaction.participantID),
  }
}

export function hashMessage(message: Message): Message {
  return ({
    ...message,
    threadID: message.threadID ? globalThreadIDHasher.hashAndRemember(message.threadID) : undefined,
    reactions: message.reactions ? message.reactions.map(hashReaction) : undefined,
    senderID: globalParticipantIDHasher.hashAndRemember(message.senderID),
  })
}

export function hashParticipant(participant: Participant): Participant {
  return {
    ...participant,
    id: globalParticipantIDHasher.hashAndRemember(participant.id),
  }
}

export function hashThread(thread: Thread): Thread {
  return ({
    ...thread,
    id: globalThreadIDHasher.hashAndRemember(thread.id),
    participants: {
      ...thread.participants,
      items: thread.participants.items.map(hashParticipant),
    },
  })
}

export default globalThreadIDHasher
