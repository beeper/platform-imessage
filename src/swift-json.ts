const SWIFT_DATE_FIELDS = new Set([
  'createdAt',
  'editedTimestamp',
  'lastActive',
  'mutedUntil',
  'seen',
  'timestamp',
])

export const swiftMapperReviver = (key: string, value: unknown): unknown => {
  if (SWIFT_DATE_FIELDS.has(key) && typeof value === 'number') return new Date(value)
  if (key === 'seen' && value && typeof value === 'object' && !Array.isArray(value) && !(value instanceof Date)) {
    return Object.fromEntries(Object.entries(value).map(([participantID, seenValue]) => [
      participantID,
      typeof seenValue === 'number' ? new Date(seenValue) : seenValue,
    ]))
  }
  return value
}

export const reviveSwiftMessageAPIValue = <T>(value: T): T => {
  const revive = (key: string, item: unknown): unknown => {
    if (Array.isArray(item)) return item.map(entry => revive('', entry))
    if (item && typeof item === 'object' && !(item instanceof Date)) {
      const revivedObject = Object.fromEntries(Object.entries(item).map(([childKey, childValue]) => [
        childKey,
        revive(childKey, childValue),
      ]))
      return swiftMapperReviver(key, revivedObject)
    }
    return swiftMapperReviver(key, item)
  }
  return revive('', value) as T
}

export const parseSwiftMessageAPIJSON = <T>(json: string): T =>
  JSON.parse(json, swiftMapperReviver) as T
