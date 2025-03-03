import { Message, MessageReaction, Participant, Thread } from '@textshq/platform-sdk'
import { threadHasher as globalThreadIDHasher, participantHasher as globalParticipantIDHasher } from './RustServer/lib'

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
