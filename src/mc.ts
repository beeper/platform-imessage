import { texts } from '@textshq/platform-sdk'
import pRetry from 'p-retry'
import { setTimeout as setTimeoutAsync } from 'node:timers/promises'
import { MessagesController, type SwiftPlatformAPI } from './SwiftServer/lib'

const timeoutSymbol = Symbol('timeout')

const timeoutAndReport = async <T>(promise: Promise<T>, ms = 120_000): Promise<T> => {
  const result = await Promise.race([
    promise,
    setTimeoutAsync(ms, timeoutSymbol),
  ])
  if (result === timeoutSymbol) throw Error('promise timed out')
  return result
}

export default class MessagesControllerWrapper {
  private static fetchPromises = new WeakMap<SwiftPlatformAPI, Promise<MessagesController>>()

  static get = async (swiftAPI: SwiftPlatformAPI) => {
    const startTime = Date.now()
    const mcPromise = MessagesControllerWrapper._getMessagesController(swiftAPI)
    const timeout = setTimeout(() => {
      texts.Sentry.captureMessage('imessage.getMC took >10s')
    }, 10_000)
    const mc = await mcPromise
    clearTimeout(timeout)
    const ms = Date.now() - startTime
    texts.log('[imsg] fetched mc in', ms, 'ms')
    if (ms > 20_000) texts.Sentry.captureMessage(`imessage.getMC took ${ms / 1000}s`)
    return mc
  }

  // serialized: if there's an existing get request running, it's reused
  private static _getMessagesController = async (swiftAPI: SwiftPlatformAPI): Promise<MessagesController> => {
    // we want to reuse existing instances of the fetch promise while any one is
    // running, but once it's done the next call to getMessagesController should
    // start up a new invocation (so that isValid() is checked again)
    const existingFetch = MessagesControllerWrapper.fetchPromises.get(swiftAPI)
    if (existingFetch) return existingFetch

    const fetchPromise = this.__getMessagesController(swiftAPI)
      .finally(() => {
        MessagesControllerWrapper.fetchPromises.delete(swiftAPI)
      })
    MessagesControllerWrapper.fetchPromises.set(swiftAPI, fetchPromise)

    return fetchPromise
  }

  // unserialized: should be serialized by the caller
  private static __getMessagesController = async (swiftAPI: SwiftPlatformAPI): Promise<MessagesController> =>
    pRetry(async () => {
      texts.log('imsg: [getMessagesController] fetching MessagesController from Swift PlatformAPI...')
      return timeoutAndReport(swiftAPI.getMessagesController()) // can throw
    }, {
      retries: 3,
      onFailedAttempt: err => {
        texts.error('imsg: [getMessagesController] errored while trying to get controller:', err)
        texts.log('imsg: [getMessagesController] retrying...')
        texts.Sentry.captureException(err, { tags: { platform: 'imessage' } })
      },
    })
}
