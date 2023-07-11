import { textsRenderer, Platform } from '@textshq/platform-sdk'

export default {
  get info() {
    return require('./info').default
  },
  get api() {
    return require('./api').default
  },
  get auth() {
    return textsRenderer.React?.lazy(() => import('./auth'))
  },
} as Platform
