import '../src/tests/fix-env'

import { reviveSwiftMapperValue } from '../src/mappers'

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
    const revived = reviveSwiftMapperValue([{ timestamp: 1000, seen: 2000, editedTimestamp: 3000 }])

    expect(revived).toEqual([{ timestamp: new Date(1000), seen: new Date(2000), editedTimestamp: new Date(3000) }])
  })
})

const messageRow = {
  ROWID: 1,
  guid: 'm1',
  date: 0,
  dateString: '0',
  date_read: 0,
  dateReadString: '0',
  date_delivered: 0,
  dateDeliveredString: '0',
  service: 'iMessage',
  room_name: '',
  participantID: 'sender@example.com',
  otherID: '',
  handle_id: 1,
  schedule_type: 0,
  is_from_me: 0,
  error: 0,
  is_delivered: 1,
  threadID: 'thread-1',
  is_read: 0,
  was_detonated: 0,
  item_type: 0,
  text: 'hello',
  balloon_bundle_id: '',
  expressive_send_style_id: '',
  subject: '',
  associated_message_guid: '',
  associated_message_type: 0,
  associated_message_emoji: '',
  thread_originator_guid: '',
  thread_originator_part: '',
}

function loadMapMessageWithSwift(mapMessageJSON: jest.Mock) {
  jest.resetModules()
  globalThis.texts = {
    ...globalThis.texts,
    error: jest.fn(),
    Sentry: {
      captureMessage: jest.fn(),
      captureException: jest.fn(),
      startTransaction: jest.fn(),
    },
  } as unknown as typeof globalThis.texts
  jest.doMock('../src/SwiftServer/lib', () => ({
    __esModule: true,
    default: {
      mapMessageJSON,
      decodeAttributedString: jest.fn(),
    },
  }))
  // eslint-disable-next-line global-require
  return require('../src/mappers') as typeof import('../src/mappers')
}

describe('mapMessage Swift wrapper', () => {
  afterEach(() => {
    jest.dontMock('../src/SwiftServer/lib')
    jest.resetModules()
  })

  test('throws when Swift throws', () => {
    const swiftError = jest.fn(() => {
      throw new Error('swift exploded')
    })
    const { mapMessage } = loadMapMessageWithSwift(swiftError)

    expect(() => mapMessage(messageRow as never, [], [], 'me@example.com', '$accountID')).toThrow('swift exploded')
  })
})
