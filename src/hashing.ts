import swiftServer from './SwiftServer/lib'

const { hashers } = swiftServer

export function hashParticipantID(id: string): string {
  return hashers.participant.tokenizeRemembering(id)
}

export function originalThreadID(possiblyHash: string): string {
  if (!possiblyHash.startsWith('imsg')) return possiblyHash

  return hashers.thread.recoverOriginal(possiblyHash)
}

export function hashThreadID(id: string): string {
  return hashers.thread.tokenizeRemembering(id)
}
