type Auth = typeof import('./auth')
type AuthApi = Parameters<Auth['runAuthorizationFlow']>[1]

function loadAuth(requiresFullDiskAccess: boolean): Auth {
  let auth!: Auth
  jest.isolateModules(() => {
    jest.doMock('../common-constants', () => ({ REQUIRES_FULL_DISK_ACCESS: requiresFullDiskAccess }))
    auth = jest.requireActual<Auth>('./auth')
  })
  return auth
}

let auth: Auth

function makeAPI({ authorized = false, grantAccess = true, databaseReady = true, folderAccess = true, grantFolderAccess = true } = {}) {
  let fullDiskAccess = authorized
  let messagesAccess = folderAccess
  const calls: string[] = []
  const api = {
    getAsset: async (_options: unknown, _path: string, method: string) => {
      calls.push(method)
      switch (method) {
        case 'getFullDiskAccessAuthStatus': return JSON.stringify(fullDiskAccess ? 'authorized' : 'denied')
        case 'getAccessibilityAuthStatus':
        case 'getContactsAuthStatus': return JSON.stringify('authorized')
        case 'askForFullDiskAccess':
          fullDiskAccess = grantAccess
          return 'null'
        case 'askForMessagesDirAccess':
          messagesAccess = grantFolderAccess
          return 'null'
        case 'canAccessMessagesDir':
        case 'isMessagesAppSetup': return JSON.stringify(databaseReady && (messagesAccess || fullDiskAccess))
        case 'askForAutomationAccess': return 'true'
        case 'confirmUNCPrompt': return 'null'
        default: throw new Error(`Unexpected authorization method: ${method}`)
      }
    },
  } as unknown as AuthApi
  return { api, calls }
}

beforeEach(() => {
  auth = loadAuth(true)
  jest.spyOn(console, 'log').mockImplementation(() => {})
})

afterEach(() => {
  jest.restoreAllMocks()
})

test('requires FDA even when folder access already makes the database readable', async () => {
  const { api, calls } = makeAPI()

  await auth.runPreflightAuthCheck('threads', [auth.DATA_AUTHORIZATION_REQUIREMENT], api)

  expect(calls.filter(method => method.startsWith('askFor'))).toEqual(['askForFullDiskAccess'])
  expect(calls.indexOf('canAccessMessagesDir')).toBeGreaterThan(calls.indexOf('askForFullDiskAccess'))
})

test('reports an unreadable database without requesting more permissions when FDA is granted', async () => {
  const { api, calls } = makeAPI({ authorized: true, databaseReady: false })

  await expect(auth.runPreflightAuthCheck('threads', [auth.DATA_AUTHORIZATION_REQUIREMENT], api))
    .rejects.toThrow('Full Disk Access is enabled, but the Messages database is unavailable')

  expect(calls.filter(method => method.startsWith('askFor'))).toEqual([])
})

test('stops before database access when FDA is denied', async () => {
  const { api, calls } = makeAPI({ grantAccess: false })
  jest.spyOn(Date, 'now').mockReturnValueOnce(0).mockReturnValue(120_000)

  await expect(auth.runPreflightAuthCheck('threads', [auth.DATA_AUTHORIZATION_REQUIREMENT], api))
    .rejects.toThrow('Full Disk Access was not granted')

  expect(calls).not.toContain('canAccessMessagesDir')
})

test.each(['all', 'full-disk-access'])('refreshes Messages readiness after granting FDA through authorize %s', async target => {
  const { api, calls } = makeAPI()

  await auth.runAuthorizationFlow(target, api)

  expect(calls.indexOf('isMessagesAppSetup')).toBeGreaterThan(calls.indexOf('askForFullDiskAccess'))
  expect(calls).not.toContain('askForMessagesDirAccess')
  expect(console.log).toHaveBeenCalledWith('  [ok] Messages.app Setup - Messages.app appears ready to use.')
})

test('does not report setup success just because FDA is enabled', async () => {
  const { api } = makeAPI({ authorized: true, databaseReady: false })

  await expect(auth.runAuthorizationFlow('full-disk-access', api))
    .rejects.toThrow('Messages.app setup could not be verified')
})

test('macOS 27+ uses FDA authorization instead of messages-data', async () => {
  const { api, calls } = makeAPI()

  expect(auth.DATA_AUTHORIZATION_REQUIREMENT).toBe('full-disk-access')
  await expect(auth.runAuthorizationFlow('messages-data', api))
    .rejects.toThrow('usage: authorize [all|accessibility|contacts|full-disk-access|automation]')

  expect(calls).toEqual([])
})

describe('macOS 26 and earlier', () => {
  beforeEach(() => {
    auth = loadAuth(false)
  })

  test('readable Messages data satisfies preflight without checking or requesting FDA', async () => {
    const { api, calls } = makeAPI()

    expect(auth.DATA_AUTHORIZATION_REQUIREMENT).toBe('messages-data')
    await auth.runPreflightAuthCheck('threads', [auth.DATA_AUTHORIZATION_REQUIREMENT], api)

    expect(calls).toEqual(['canAccessMessagesDir'])
  })

  test('preflight requests the Messages folder when access is missing', async () => {
    const { api, calls } = makeAPI({ folderAccess: false })

    await auth.runPreflightAuthCheck('threads', [auth.DATA_AUTHORIZATION_REQUIREMENT], api)

    expect(calls.filter(method => method.startsWith('askFor'))).toEqual(['askForMessagesDirAccess'])
    expect(calls).not.toContain('getFullDiskAccessAuthStatus')
  })

  test('falls back to FDA if folder authorization does not grant access', async () => {
    const { api, calls } = makeAPI({ folderAccess: false, grantFolderAccess: false })

    await auth.runPreflightAuthCheck('threads', [auth.DATA_AUTHORIZATION_REQUIREMENT], api)

    expect(calls.filter(method => method.startsWith('askFor'))).toEqual(['askForMessagesDirAccess', 'askForFullDiskAccess'])
  })

  test('fails if neither folder access nor the FDA fallback makes the database readable', async () => {
    const { api } = makeAPI({ folderAccess: false, grantFolderAccess: false, grantAccess: false })

    await expect(auth.runPreflightAuthCheck('threads', [auth.DATA_AUTHORIZATION_REQUIREMENT], api))
      .rejects.toThrow('Messages Data was not granted')
  })

  test.each(['all', 'messages-data'])('authorize %s accepts folder access without FDA', async target => {
    const { api, calls } = makeAPI({ folderAccess: false })

    await auth.runAuthorizationFlow(target, api)

    expect(calls).toContain('askForMessagesDirAccess')
    expect(calls).not.toContain('getFullDiskAccessAuthStatus')
    expect(calls).not.toContain('askForFullDiskAccess')
    if (target === 'all') {
      expect(calls.lastIndexOf('isMessagesAppSetup')).toBeGreaterThan(calls.indexOf('askForMessagesDirAccess'))
      expect(console.log).toHaveBeenCalledWith('  [ok] Messages.app Setup - Messages.app appears ready to use.')
    }
  })
})
