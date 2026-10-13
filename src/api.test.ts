import './tests/fix-env'

import { promises as fs } from 'fs'
import { ReAuthError, texts } from '@textshq/platform-sdk'
import AppleiMessage from './api'
import imessage, { type NativePlatformAPI } from './IMessage/lib'

let mockRequiresFullDiskAccess = true

jest.mock('./IMessage/lib', () => ({
  __esModule: true,
  default: {
    PlatformAPI: jest.fn(),
    MacPermissions: {
      getAuthStatus: jest.fn(),
      validateDatabaseAccess: jest.fn(),
      askForFullDiskAccess: jest.fn(),
    },
  },
}))
jest.mock('./csr', () => ({ csrStatus: async () => 'enabled.' }))
jest.mock('./persistence', () => ({ makeJSONPersistence: async () => ({}) }))
jest.mock('./common-constants', () => ({
  ...jest.requireActual('./common-constants') as typeof import('./common-constants'),
  IS_BIG_SUR_OR_UP: true,
  get REQUIRES_FULL_DISK_ACCESS() { return mockRequiresFullDiskAccess },
}))

const context = { accountID: 'test-account', dataDirPath: '/test/imessage/account' }
const currentUser = { id: 'test-user' }
const nativeAPI = { getCurrentUser: jest.fn() }
const permissions = jest.mocked(imessage.MacPermissions)

beforeEach(() => {
  mockRequiresFullDiskAccess = true
  jest.clearAllMocks()
  Object.assign(texts, { log: jest.fn(), error: jest.fn(), trackPlatformEvent: jest.fn() })
  jest.spyOn(fs, 'readFile').mockResolvedValue('')
  jest.mocked(imessage.PlatformAPI).mockImplementation(() => nativeAPI as unknown as NativePlatformAPI)
  nativeAPI.getCurrentUser.mockResolvedValue(JSON.stringify(currentUser))
  permissions.getAuthStatus.mockReturnValue('denied')
  permissions.validateDatabaseAccess.mockResolvedValue(undefined)
})

afterEach(() => {
  jest.restoreAllMocks()
})

test.each([undefined, {}])('initialization keeps authorization available without FDA (session: %p)', async session => {
  const api = new AppleiMessage(context.accountID)

  await api.init(session, context)

  expect(permissions.getAuthStatus).not.toHaveBeenCalled()
  await expect(api.getAsset(undefined, 'proxied', 'getFullDiskAccessAuthStatus')).resolves.toBe('"denied"')
  await api.getAsset(undefined, 'proxied', 'askForFullDiskAccess')
  expect(permissions.askForFullDiskAccess).toHaveBeenCalledTimes(1)
})

test.each(['denied', 'restricted', 'not determined'] as const)('restoring an account requires reauthorization when FDA is %s', async status => {
  permissions.getAuthStatus.mockReturnValue(status)
  const api = new AppleiMessage(context.accountID)
  await api.init({}, context)

  await expect(api.getCurrentUser()).rejects.toBeInstanceOf(ReAuthError)

  expect(permissions.getAuthStatus).toHaveBeenCalledWith('full-disk-access')
  expect(nativeAPI.getCurrentUser).not.toHaveBeenCalled()
})

test('login requires FDA even if Messages database access would succeed', async () => {
  const api = new AppleiMessage(context.accountID)
  await api.init(undefined, context)

  await expect(api.login()).resolves.toEqual({
    type: 'error',
    errorMessage: expect.stringContaining('Full Disk Access is required'),
  })
  expect(permissions.validateDatabaseAccess).not.toHaveBeenCalled()
})

test('an account recovers after FDA is granted and requires reauthorization if it is revoked', async () => {
  const api = new AppleiMessage(context.accountID)
  await api.init({}, context)
  await expect(api.getCurrentUser()).rejects.toBeInstanceOf(ReAuthError)

  permissions.getAuthStatus.mockReturnValue('authorized')
  await expect(api.login()).resolves.toEqual({ type: 'success' })
  expect(permissions.validateDatabaseAccess).toHaveBeenCalledTimes(1)
  await expect(api.getCurrentUser()).resolves.toEqual(currentUser)

  permissions.getAuthStatus.mockReturnValue('denied')
  await expect(api.getCurrentUser()).rejects.toBeInstanceOf(ReAuthError)
  expect(nativeAPI.getCurrentUser).toHaveBeenCalledTimes(1)
})

test('FDA alone does not complete login when the Messages database is unavailable', async () => {
  permissions.getAuthStatus.mockReturnValue('authorized')
  permissions.validateDatabaseAccess.mockRejectedValue(new Error('database unavailable'))
  const api = new AppleiMessage(context.accountID)
  await api.init(undefined, context)

  await expect(api.login()).resolves.toEqual({
    type: 'error',
    errorMessage: expect.stringContaining('Open Messages.app and finish setup'),
  })
})

test.each(['denied', 'restricted', 'not determined'] as const)('macOS 26 and earlier allow restore and login when FDA is %s', async status => {
  mockRequiresFullDiskAccess = false
  permissions.getAuthStatus.mockReturnValue(status)
  const api = new AppleiMessage(context.accountID)
  await api.init({}, context)

  await expect(api.getCurrentUser()).resolves.toEqual(currentUser)
  await expect(api.login()).resolves.toEqual({ type: 'success' })
  expect(permissions.getAuthStatus).not.toHaveBeenCalled()
  expect(permissions.validateDatabaseAccess).toHaveBeenCalledTimes(1)
})

test('macOS 26 and earlier still validate the database during login', async () => {
  mockRequiresFullDiskAccess = false
  permissions.validateDatabaseAccess.mockRejectedValue(new Error('database unavailable'))
  const api = new AppleiMessage(context.accountID)
  await api.init(undefined, context)

  await expect(api.login()).resolves.toEqual({
    type: 'error',
    errorMessage: expect.stringContaining('Open Messages.app and finish setup'),
  })
  expect(permissions.getAuthStatus).not.toHaveBeenCalled()
})
