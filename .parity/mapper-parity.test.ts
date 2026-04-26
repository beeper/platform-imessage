import '../src/tests/fix-env'

import { swiftMapperReviver } from '../src/swift-json'

type MapperDiff = {
  path: string
  kind: 'missing-in-swift' | 'missing-in-typescript' | 'type' | 'value' | 'length'
}

const normalizeMapperValue = (value: unknown): unknown => {
  if (value instanceof Date) return { $date: value.getTime() }
  if (Array.isArray(value)) return value.map(normalizeMapperValue)
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key, entryValue]) => key !== '_original' && entryValue !== undefined)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, entryValue]) => [key, normalizeMapperValue(entryValue)]),
    )
  }
  return value
}

function mapperValueType(value: unknown) {
  if (Array.isArray(value)) return 'array'
  if (value === null) return 'null'
  return typeof value
}

function diffNormalizedMapperValues(swiftValue: unknown, typescriptValue: unknown, path = '$', diffs: MapperDiff[] = []): MapperDiff[] {
  if (diffs.length >= 20) return diffs
  if (Object.is(swiftValue, typescriptValue)) return diffs

  const swiftType = mapperValueType(swiftValue)
  const typescriptType = mapperValueType(typescriptValue)
  if (swiftType !== typescriptType) {
    diffs.push({ path, kind: 'type' })
    return diffs
  }

  if (Array.isArray(swiftValue) && Array.isArray(typescriptValue)) {
    if (swiftValue.length !== typescriptValue.length) diffs.push({ path, kind: 'length' })
    const length = Math.min(swiftValue.length, typescriptValue.length)
    for (let i = 0; i < length; i++) {
      diffNormalizedMapperValues(swiftValue[i], typescriptValue[i], `${path}[${i}]`, diffs)
    }
    return diffs
  }

  if (swiftValue && typeof swiftValue === 'object' && typescriptValue && typeof typescriptValue === 'object') {
    const swiftRecord = swiftValue as Record<string, unknown>
    const typescriptRecord = typescriptValue as Record<string, unknown>
    const keys = new Set([...Object.keys(swiftRecord), ...Object.keys(typescriptRecord)])
    for (const key of [...keys].sort()) {
      if (diffs.length >= 20) break
      if (!(key in swiftRecord)) {
        diffs.push({ path: `${path}.${key}`, kind: 'missing-in-swift' })
      } else if (!(key in typescriptRecord)) {
        diffs.push({ path: `${path}.${key}`, kind: 'missing-in-typescript' })
      } else {
        diffNormalizedMapperValues(swiftRecord[key], typescriptRecord[key], `${path}.${key}`, diffs)
      }
    }
    return diffs
  }

  diffs.push({ path, kind: 'value' })
  return diffs
}

describe('mapper parity helpers', () => {
  test('normalizes dates and ignores _original', () => {
    const swift = normalizeMapperValue([{ id: 'm1', timestamp: new Date(1000) }])
    const typescript = normalizeMapperValue([{ id: 'm1', timestamp: new Date(1000), _original: 'debug' }])

    expect(diffNormalizedMapperValues(swift, typescript)).toEqual([])
  })

  test('treats absent and undefined fields as equal after normalization', () => {
    const swift = normalizeMapperValue([{ id: 'm1' }])
    const typescript = normalizeMapperValue([{ id: 'm1', seen: undefined }])

    expect(diffNormalizedMapperValues(swift, typescript)).toEqual([])
  })

  test('reports divergent paths without values', () => {
    const swift = normalizeMapperValue([{ id: 'm1', text: 'new' }])
    const typescript = normalizeMapperValue([{ id: 'm1', text: 'old' }])

    expect(diffNormalizedMapperValues(swift, typescript)).toEqual([
      { path: '$[0].text', kind: 'value' },
    ])
  })

  test('revives swift date fields from milliseconds', () => {
    const revived = JSON.parse(
      JSON.stringify([{ timestamp: 1000, seen: 2000, editedTimestamp: 3000 }]),
      swiftMapperReviver,
    )

    expect(revived).toEqual([{ timestamp: new Date(1000), seen: new Date(2000), editedTimestamp: new Date(3000) }])
  })
})
