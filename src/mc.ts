import { texts } from '@textshq/platform-sdk'
import pRetry from 'p-retry'
import { setTimeout as setTimeoutAsync } from 'timers/promises'
import swiftServer, { MessagesController } from './SwiftServer/lib'
import { IS_BIG_SUR_OR_UP } from './common-constants'

const messagesControllerClass = swiftServer?.messagesControllerClass

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
  private static fetchPromise?: Promise<MessagesController>

  private static controller?: MessagesController

  static forceInvalidate = false

  static get = async () => {
    const startTime = Date.now()
    const mcPromise = MessagesControllerWrapper._getMessagesController()
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
  private static _getMessagesController = async (): Promise<MessagesController> => {
    if (!IS_BIG_SUR_OR_UP) throw new Error('MessagesController is only supported on macOS Big Sur and later')

    // we want to reuse existing instances of the fetch promise while any one is
    // running, but once it's done the next call to getMessagesController should
    // start up a new invocation (so that isValid() is checked again)
    if (MessagesControllerWrapper.fetchPromise) return MessagesControllerWrapper.fetchPromise

    MessagesControllerWrapper.fetchPromise = this.__getMessagesController()
      .finally(() => {
        MessagesControllerWrapper.fetchPromise = undefined
      })

    return MessagesControllerWrapper.fetchPromise
  }

  // unserialized: should be serialized by the caller
  private static __getMessagesController = async (): Promise<MessagesController> =>
    pRetry(async () => {
      let { controller } = MessagesControllerWrapper
      if (!controller) {
        texts.log('imsg: [getMessagesController] creating MessagesController...')
        controller = await timeoutAndReport(messagesControllerClass.create()) // can throw
        MessagesControllerWrapper.controller = controller
      }

      const controllerValid = await controller.isValid()
      const isForcingInvalidation = MessagesControllerWrapper.forceInvalidate
      if (!controllerValid || isForcingInvalidation) {
        texts.log(`imsg: [getMessagesController] DISPOSING MessagesController (valid? ${controllerValid}, invalidation forced? ${isForcingInvalidation})`)
        texts.trackPlatformEvent({
          platform: 'imessage',
          message: 'disposing MessagesController',
          forceInvalidate: MessagesControllerWrapper.forceInvalidate,
        })
        MessagesControllerWrapper.forceInvalidate = false
        MessagesControllerWrapper.controller = undefined
        controller.dispose()
        throw new Error('MessagesController is invalid')
      }
      return controller
    }, {
      retries: 3,
      onFailedAttempt: err => {
        texts.error('imsg: [getMessagesController] errored while trying to get controller:', err)
        texts.log('imsg: [getMessagesController] retrying...')
        texts.Sentry.captureException(err, { tags: { platform: 'imessage' } })
      },
    })

  static async dispose() {
    const controller = (await MessagesControllerWrapper.fetchPromise) || MessagesControllerWrapper.controller
    controller?.dispose()
    MessagesControllerWrapper.controller = undefined
  }
}
