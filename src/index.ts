import { textsRenderer, Platform, PlatformAPI } from '@textshq/platform-sdk'
import info from './info'
import AppleiMessage from './api'

export default {
  get info() {
    return info
  },
  get api() {
    return AppleiMessage as unknown as PlatformAPI
  },
  get auth() {
    // eslint-disable-next-line import/extensions
    return textsRenderer.React?.lazy(() => import('./auth'))
  },
} as Platform
