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

const reviveSwiftDateFields = (record: Record<string, unknown>): void => {
  SWIFT_DATE_FIELDS.forEach(field => {
    if (field in record) record[field] = swiftMapperReviver(field, record[field])
  })
}

const reviveSwiftEventEntry = (entry: unknown): void => {
  if (isMutableRecord(entry)) reviveSwiftDateFields(entry)
}

export const reviveSwiftMessageAPIValue = <T>(value: T): T => {
  // Intentionally mutates already-parsed Swift bridge payloads in place. These
  // values are transient event objects. Keep the work targeted to the event
  // envelope and state-sync entries instead of walking attachments/extras.
  if (Array.isArray(value)) {
    value.forEach(reviveSwiftEventEntry)
    return value
  }
  if (!isMutableRecord(value)) return swiftMapperReviver('', value) as T

  reviveSwiftDateFields(value)

  if (Array.isArray(value.entries)) {
    value.entries.forEach(reviveSwiftEventEntry)
  }
  if (isMutableRecord(value.presence)) {
    reviveSwiftDateFields(value.presence)
  }

  return value
}

export const parseSwiftMessageAPIJSON = <T>(json: string): T =>
  JSON.parse(json, swiftMapperReviver) as T
