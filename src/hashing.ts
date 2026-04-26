import swiftServer from './SwiftServer/lib'

export function hashParticipantID(id: string): string {
  return swiftServer.hashParticipantID(id)
}
