const dateFields = new Set(['timestamp', 'seen', 'editedTimestamp'])

function normalizeParityValue(value, key) {
  if (value instanceof Date) return { $date: value.getTime() }
  if (dateFields.has(key) && typeof value === 'number') return { $date: value }
  if (Array.isArray(value)) return value.map(item => normalizeParityValue(item))
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([entryKey, entryValue]) => entryKey !== '_original' && entryValue != null)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([entryKey, entryValue]) => [entryKey, normalizeParityValue(entryValue, entryKey)]),
    )
  }
  return value
}

function normalizeCursorPrecision(value) {
  const text = typeof value === 'number' ? String(value) : value
  if (typeof text !== 'string' || !/^\d{16,}$/.test(text)) return value

  const rounded = Number(text)
  return Number.isFinite(rounded) ? rounded.toString() : value
}

function normalizeForParityDelta(phase, value) {
  const normalized = normalizeParityValue(value)
  if (
    phase !== 'searchMessages'
    || !normalized
    || typeof normalized !== 'object'
    || Array.isArray(normalized)
    || !('oldestCursor' in normalized)
  ) {
    return normalized
  }

  return {
    ...normalized,
    oldestCursor: normalizeCursorPrecision(normalized.oldestCursor),
  }
}

const valueType = value => Array.isArray(value) ? 'array' : value === null ? 'null' : typeof value

function allowCurrentOnlyReferenceDrift(key, swiftValue) {
  // The legacy JS mapper intentionally omitted isUnread and let Desktop derive
  // it from unreadCount/isMarkedUnread. Current Swift mirrors the SDK shape, so
  // do not let that reference-era field drift swamp mapper parity.
  return key === 'isUnread' && typeof swiftValue === 'boolean'
}

function diffParityValues(swiftValue, referenceValue, pathName = '$', diffs = []) {
  if (diffs.length >= 20 || Object.is(swiftValue, referenceValue)) return diffs
  const swiftType = valueType(swiftValue)
  const referenceType = valueType(referenceValue)
  if (swiftType !== referenceType) {
    diffs.push({ path: pathName, kind: 'type' })
    return diffs
  }
  if (Array.isArray(swiftValue) && Array.isArray(referenceValue)) {
    if (swiftValue.length !== referenceValue.length) diffs.push({ path: pathName, kind: 'length' })
    for (let index = 0; index < Math.min(swiftValue.length, referenceValue.length); index++) {
      diffParityValues(swiftValue[index], referenceValue[index], `${pathName}[${index}]`, diffs)
    }
    return diffs
  }
  if (swiftValue && typeof swiftValue === 'object' && referenceValue && typeof referenceValue === 'object') {
    const keys = new Set([...Object.keys(swiftValue), ...Object.keys(referenceValue)])
    for (const key of [...keys].sort()) {
      if (diffs.length >= 20) break
      if (!(key in swiftValue)) diffs.push({ path: `${pathName}.${key}`, kind: 'missing-in-swift' })
      else if (!(key in referenceValue)) {
        if (!allowCurrentOnlyReferenceDrift(key, swiftValue[key])) {
          diffs.push({ path: `${pathName}.${key}`, kind: 'missing-in-reference' })
        }
      } else {
        diffParityValues(swiftValue[key], referenceValue[key], `${pathName}.${key}`, diffs)
      }
    }
    return diffs
  }
  diffs.push({ path: pathName, kind: 'value' })
  return diffs
}

module.exports = {
  diffParityValues,
  normalizeForParityDelta,
  normalizeParityValue,
}
