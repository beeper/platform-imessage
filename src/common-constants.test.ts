import './tests/fix-env'

import os from 'os'

afterEach(() => {
  jest.restoreAllMocks()
})

test.each([
  ['24.6.0', false],
  ['25.5.0', false],
  ['26.0.0', true],
  ['27.0.0', true],
])('FDA requirement for Darwin %s is %s', (release, required) => {
  jest.spyOn(os, 'release').mockReturnValue(release as string)
  jest.isolateModules(() => {
    const { REQUIRES_FULL_DISK_ACCESS } = jest.requireActual<typeof import('./common-constants')>('./common-constants')
    expect(REQUIRES_FULL_DISK_ACCESS).toBe(required)
  })
})
