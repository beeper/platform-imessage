import { runAuthorizationFlow, runPreflightAuthCheck } from './auth'

type AuthApi = Parameters<typeof runAuthorizationFlow>[1]

function makeAPI({ authorized = false, grantAccess = true, databaseReady = true } = {}) {
  let fullDiskAccess = authorized
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
        case 'canAccessMessagesDir': return JSON.stringify(databaseReady)
        case 'isMessagesAppSetup': return JSON.stringify(fullDiskAccess && databaseReady)
        case 'askForAutomationAccess': return 'true'
        case 'confirmUNCPrompt': return 'null'
        default: throw new Error(`Unexpected authorization method: ${method}`)
      }
    },
  } as unknown as AuthApi
  return { api, calls }
}

beforeEach(() => {
  jest.spyOn(console, 'log').mockImplementation(() => {})
})

afterEach(() => {
  jest.restoreAllMocks()
})

test('requires FDA even when folder access already makes the database readable', async () => {
  const { api, calls } = makeAPI()

  await runPreflightAuthCheck('threads', ['full-disk-access'], api)

  expect(calls.filter(method => method.startsWith('askFor'))).toEqual(['askForFullDiskAccess'])
  expect(calls.indexOf('canAccessMessagesDir')).toBeGreaterThan(calls.indexOf('askForFullDiskAccess'))
})

test('reports an unreadable database without requesting more permissions when FDA is granted', async () => {
  const { api, calls } = makeAPI({ authorized: true, databaseReady: false })

  await expect(runPreflightAuthCheck('threads', ['full-disk-access'], api))
    .rejects.toThrow('Full Disk Access is enabled, but the Messages database is unavailable')

  expect(calls.filter(method => method.startsWith('askFor'))).toEqual([])
})

test('stops before database access when FDA is denied', async () => {
  const { api, calls } = makeAPI({ grantAccess: false })
  jest.spyOn(Date, 'now').mockReturnValueOnce(0).mockReturnValue(120_000)

  await expect(runPreflightAuthCheck('threads', ['full-disk-access'], api))
    .rejects.toThrow('Full Disk Access was not granted')

  expect(calls).not.toContain('canAccessMessagesDir')
})

test.each(['all', 'full-disk-access'])('refreshes Messages readiness after granting FDA through authorize %s', async target => {
  const { api, calls } = makeAPI()

  await runAuthorizationFlow(target, api)

  expect(calls.indexOf('isMessagesAppSetup')).toBeGreaterThan(calls.indexOf('askForFullDiskAccess'))
  expect(calls).not.toContain('askForMessagesDirAccess')
  expect(console.log).toHaveBeenCalledWith('  [ok] Messages.app Setup - Messages.app appears ready to use.')
})

test('does not report setup success just because FDA is enabled', async () => {
  const { api } = makeAPI({ authorized: true, databaseReady: false })

  await expect(runAuthorizationFlow('full-disk-access', api))
    .rejects.toThrow('Messages.app setup could not be verified')
})

test('rejects the retired messages-data authorization target', async () => {
  const { api, calls } = makeAPI()

  await expect(runAuthorizationFlow('messages-data', api))
    .rejects.toThrow('usage: authorize [all|accessibility|contacts|full-disk-access|automation]')

  expect(calls).toEqual([])
})
