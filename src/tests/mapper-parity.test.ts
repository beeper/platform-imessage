import './fix-env'

import { __mapperParityTest } from '../mappers'

const {
  diffNormalizedMapperValues,
  normalizeMapperValue,
  projectSwiftToTypescriptShape,
  reviveSwiftMapperValue,
} = __mapperParityTest

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

  test('projects swift output through the typescript oracle shape', () => {
    const date = new Date(1000)
    const restored = projectSwiftToTypescriptShape(
      [{ id: 'm1', timestamp: date, swiftOnly: true }],
      [{ id: 'm1', timestamp: new Date(1000), seen: undefined }],
    )

    expect(restored).toEqual([{ id: 'm1', timestamp: date, seen: undefined }])
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

function loadMapMessageWithSwift(mapMessageJSON: jest.Mock, strict = false) {
  jest.resetModules()
  process.env.IMESSAGE_SWIFT_MAP_MESSAGE_STRICT = strict ? '1' : ''
  globalThis.texts = {
    ...globalThis.texts,
    error: jest.fn(),
    Sentry: {
      captureMessage: jest.fn(),
      captureException: jest.fn(),
      startTransaction: jest.fn(),
    },
  } as unknown as typeof globalThis.texts
  jest.doMock('../SwiftServer/lib', () => ({
    __esModule: true,
    default: {
      mapMessageJSON,
      decodeAttributedString: jest.fn(),
    },
  }))
  return require('../mappers') as typeof import('../mappers')
}

describe('mapMessage swift parity guard', () => {
  afterEach(() => {
    delete process.env.IMESSAGE_SWIFT_MAP_MESSAGE_STRICT
    jest.dontMock('../SwiftServer/lib')
    jest.resetModules()
  })

  test('returns typescript output and reports when swift throws', () => {
    const swiftError = jest.fn(() => {
      throw new Error('swift exploded')
    })
    const { mapMessage } = loadMapMessageWithSwift(swiftError)

    const messages = mapMessage(messageRow as never, [], [], 'me@example.com', '$accountID')

    expect(messages).toHaveLength(1)
    expect(messages[0].text).toBe('hello')
    expect(globalThis.texts.error).toHaveBeenCalledWith(expect.stringContaining('guid=m1'))
    expect(globalThis.texts.error).not.toHaveBeenCalledWith(expect.stringContaining('hello'))
  })

  test('throws on swift failure in strict mode', () => {
    const swiftError = jest.fn(() => {
      throw new Error('swift exploded')
    })
    const { mapMessage } = loadMapMessageWithSwift(swiftError, true)

    expect(() => mapMessage(messageRow as never, [], [], 'me@example.com', '$accountID')).toThrow('Swift mapMessage failed for m1')
  })
})
