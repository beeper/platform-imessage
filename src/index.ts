import type { Platform } from '@textshq/platform-sdk'

export default {
  get info() {
    return require('./info').default
  },
  get api() {
    return require('./api').default
  },
} as Platform
