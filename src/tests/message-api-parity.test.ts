import './fix-env'

const baseMessage = {
  id: 'm1',
  cursor: '1',
  timestamp: new Date(1000),
  sortKey: 1000,
  senderID: 'imsg##participant:sender',
  isSender: false,
  isErrored: false,
  isDelivered: true,
  threadID: 'imsg##thread:t1',
}

function loadAPI({
  swiftGetMessages = jest.fn(async () => JSON.stringify({ items: [{ ...baseMessage, timestamp: 1000 }], hasMore: false })),
  swiftGetMessage = jest.fn(async () => JSON.stringify({ ...baseMessage, timestamp: 1000 })),
  legacyGetMessages = jest.fn(async () => ({ items: [baseMessage], hasMore: false })),
  legacyGetMessage = jest.fn(async () => baseMessage),
  strict = false,
} = {}) {
  jest.resetModules()
  process.env.IMESSAGE_SKIP_EAGER_MC = '1'
  process.env.IMESSAGE_SWIFT_MAP_MESSAGE_STRICT = strict ? '1' : ''
  globalThis.texts = {
    ...globalThis.texts,
    isLoggingEnabled: false,
    log: jest.fn(),
    error: jest.fn(),
    Sentry: {
      captureMessage: jest.fn(),
      captureException: jest.fn(),
      startTransaction: jest.fn(),
    },
    trackPlatformEvent: jest.fn(),
  } as unknown as typeof globalThis.texts

  jest.doMock('../SwiftServer/lib', () => ({
    __esModule: true,
    ActivityStatus: {},
    default: {
      isLoggingEnabled: false,
      getMessages: swiftGetMessages,
      getMessage: swiftGetMessage,
      getDNDList: jest.fn(() => []),
      cancelPollingIfNecessary: jest.fn(),
      hashers: {
        thread: {
          tokenizeRemembering: jest.fn((value: string) => value.startsWith('imsg##thread:') ? value : `imsg##thread:${value}`),
          recoverOriginal: jest.fn((value: string) => value.replace(/^imsg##thread:/, '')),
        },
        participant: {
          tokenizeRemembering: jest.fn((value: string) => value.startsWith('imsg##participant:') ? value : `imsg##participant:${value}`),
          recoverOriginal: jest.fn((value: string) => value.replace(/^imsg##participant:/, '')),
        },
      },
    },
  }))
  jest.doMock('../db-api', () => ({
    __esModule: true,
    THREADS_LIMIT: 25,
    MESSAGES_LIMIT: 20,
    default: {
      make: jest.fn(async () => ({
        getAccountLogins: jest.fn(async () => ['E:me@example.com']),
        warmThreadHasher: jest.fn(),
      })),
    },
  }))
  jest.doMock('../messages-legacy', () => ({
    __esModule: true,
    getMessagesLegacy: legacyGetMessages,
    getMessageLegacy: legacyGetMessage,
  }))
  jest.doMock('p-retry', () => ({
    __esModule: true,
    default: jest.fn((fn: () => unknown) => fn()),
  }))
  jest.doMock('p-queue', () => ({
    __esModule: true,
    default: class MockPQueue {
      add(fn: () => unknown) {
        return fn()
      }
    },
  }))
  jest.doMock('../mc', () => ({
    __esModule: true,
    default: {
      get: jest.fn(),
      dispose: jest.fn(),
    },
  }))

  return require('../api').default as typeof import('../api').default
}

describe('Swift message API parity guard', () => {
  afterEach(() => {
    delete process.env.IMESSAGE_SWIFT_MAP_MESSAGE_STRICT
    jest.dontMock('../SwiftServer/lib')
    jest.dontMock('../db-api')
    jest.dontMock('../messages-legacy')
    jest.dontMock('p-retry')
    jest.dontMock('p-queue')
    jest.dontMock('../mc')
    jest.resetModules()
  })

  test('getMessages returns revived Swift output', async () => {
    const AppleiMessage = loadAPI()
    const api = new AppleiMessage('default')

    const result = await api.getMessages('imsg##thread:t1')

    expect(result.items[0].timestamp).toEqual(new Date(1000))
    expect(globalThis.texts.error).not.toHaveBeenCalled()
  })

  test('getMessage reports divergence but returns Swift output', async () => {
    const legacyGetMessage = jest.fn(async () => ({ ...baseMessage, text: 'legacy' }))
    const swiftGetMessage = jest.fn(async () => JSON.stringify({ ...baseMessage, timestamp: 1000, text: 'swift' }))
    const AppleiMessage = loadAPI({ swiftGetMessage, legacyGetMessage })
    const api = new AppleiMessage('default')

    const result = await api.getMessage('imsg##thread:t1', 'm1')

    expect(result?.text).toBe('swift')
    expect(globalThis.texts.error).toHaveBeenCalledWith(expect.stringContaining('diffs=$.text:value'))
    expect(globalThis.texts.error).not.toHaveBeenCalledWith(expect.stringContaining('legacy'))
  })

  test('getMessages throws on strict divergence', async () => {
    const legacyGetMessages = jest.fn(async () => ({ items: [{ ...baseMessage, text: 'legacy' }], hasMore: false }))
    const swiftGetMessages = jest.fn(async () => JSON.stringify({ items: [{ ...baseMessage, timestamp: 1000, text: 'swift' }], hasMore: false }))
    const AppleiMessage = loadAPI({ swiftGetMessages, legacyGetMessages, strict: true })
    const api = new AppleiMessage('default')

    await expect(api.getMessages('imsg##thread:t1')).rejects.toThrow('Swift getMessages diverged')
  })

  test('getMessage falls back to legacy on Swift error outside strict mode', async () => {
    const legacyGetMessage = jest.fn(async () => ({ ...baseMessage, text: 'legacy' }))
    const swiftGetMessage = jest.fn(async () => {
      throw new Error('swift exploded')
    })
    const AppleiMessage = loadAPI({ swiftGetMessage, legacyGetMessage })
    const api = new AppleiMessage('default')

    const result = await api.getMessage('imsg##thread:t1', 'm1')

    expect(result?.text).toBe('legacy')
    expect(globalThis.texts.error).toHaveBeenCalledWith(expect.stringContaining('iMessage Swift message API error'))
  })
})
