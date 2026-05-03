const SWIFT_DATE_FIELDS = new Set([
  'createdAt',
  'editedTimestamp',
  'lastActive',
  'mutedUntil',
  'seen',
  'timestamp',
])

const isMutableRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === 'object' && !Array.isArray(value) && !(value instanceof Date)

export const swiftMapperReviver = (key: string, value: unknown): unknown => {
  if (SWIFT_DATE_FIELDS.has(key) && typeof value === 'number') return new Date(value)
  if (key === 'seen' && isMutableRecord(value)) {
    const seenByParticipantID = value
    Object.entries(seenByParticipantID).forEach(([participantID, seenValue]) => {
      if (typeof seenValue === 'number') seenByParticipantID[participantID] = new Date(seenValue)
    })
  }
  return value
}

export const reviveSwiftMessageAPIValue = <T>(value: T): T => {
  // Intentionally mutates already-parsed Swift bridge payloads in place. These
  // values are transient event objects, and avoiding deep clones keeps event
  // normalization cheap on busy state-sync paths.
  const revive = (key: string, item: unknown): unknown => {
    if (Array.isArray(item)) {
      const array = item
      array.forEach((entry, index) => {
        array[index] = revive('', entry)
      })
      return array
    }
    if (isMutableRecord(item)) {
      const record = item
      Object.entries(record).forEach(([childKey, childValue]) => {
        record[childKey] = revive(childKey, childValue)
      })
      return swiftMapperReviver(key, record)
    }
    return swiftMapperReviver(key, item)
  }
  return revive('', value) as T
}

export const parseSwiftMessageAPIJSON = <T>(json: string): T =>
  JSON.parse(json, swiftMapperReviver) as T
