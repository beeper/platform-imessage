const SWIFT_DATE_FIELDS = new Set(['timestamp', 'seen', 'editedTimestamp'])

export const reviveSwiftMapperValue = (value: unknown, key?: string): unknown => {
  if (SWIFT_DATE_FIELDS.has(key ?? '') && typeof value === 'number') return new Date(value)
  if (Array.isArray(value)) return value.map(item => reviveSwiftMapperValue(item))
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([entryKey, entryValue]) => [entryKey, reviveSwiftMapperValue(entryValue, entryKey)]),
    )
  }
  return value
}
