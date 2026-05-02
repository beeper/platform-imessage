const SWIFT_DATE_FIELDS = new Set(['timestamp', 'seen', 'editedTimestamp'])

export const swiftMapperReviver = (key: string, value: unknown): unknown =>
  SWIFT_DATE_FIELDS.has(key) && typeof value === 'number' ? new Date(value) : value

export const parseSwiftMessageAPIJSON = <T>(json: string): T =>
  JSON.parse(json, swiftMapperReviver) as T
