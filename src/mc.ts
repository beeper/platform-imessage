import { texts } from '@textshq/platform-sdk'
import swiftServer, { MessagesController } from './SwiftServer/lib'
import { IS_BIG_SUR_OR_UP } from './common-constants'

const messagesControllerClass = swiftServer?.messagesControllerClass

export default class MessagesControllerWrapper {
  private static fetchPromise: Promise<MessagesController>

  private static createPromise: Promise<MessagesController>

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

  // here be dragons
  private static _getMessagesController = async (attempt = 0): Promise<MessagesController> => {
    if (!IS_BIG_SUR_OR_UP) return

    // we want to reuse existing instances of the fetch promise while any one is
    // running, but once it's done the next call to getMessagesController should
    // start up a new invocation (so that isValid() is checked again)
    //
    // the create promise, meanwhile, should be recreated sparingly: only if a previous
    // create() call failed, or inside the fetch promise when isValid is false (in either
    // case, the main fetchPromsie closure will throw and be caught by the catch)
    if (!MessagesControllerWrapper.fetchPromise) {
      MessagesControllerWrapper.fetchPromise = (async () => {
        if (!MessagesControllerWrapper.createPromise) {
          texts.log('creating MessagesController...')
          MessagesControllerWrapper.createPromise = messagesControllerClass.create()
        }
        const controller = await MessagesControllerWrapper.createPromise
        if (!(await controller.isValid()) || MessagesControllerWrapper.forceInvalidate) {
          texts.trackPlatformEvent({
            platform: 'imessage',
            message: 'disposing MessagesController',
            forceInvalidate: MessagesControllerWrapper.forceInvalidate,
          })
          MessagesControllerWrapper.forceInvalidate = false
          controller.dispose()
          throw new Error('MessagesController is invalid')
        }
        return controller
      })().finally(() => {
        // this `finally` must run *before* the catch since the catch recurses
        // getMessagesController, and when that happens the fetch promise should
        // already be undefined
        MessagesControllerWrapper.fetchPromise = undefined
      }).catch(err => {
        // we always unset createPromise here, but only auto-retry up to twice.
        // This means that a single call to getMessagesController() will spawn
        // at most three create() calls, but if all three fail then a future call
        // to getMessagesController() can spawn up to three more again
        MessagesControllerWrapper.createPromise = undefined
        texts.error('[imessage] getMessagesController', err)
        if (attempt > 2) {
          texts.Sentry.captureException(err, { tags: { platform: 'imessage' } })
          throw err
        }
        texts.log('retrying...')
        return MessagesControllerWrapper._getMessagesController(attempt + 1)
      })
    }
    return MessagesControllerWrapper.fetchPromise
  }

  static async dispose() {
    if (MessagesControllerWrapper.createPromise) (await MessagesControllerWrapper.get()).dispose()
  }
}
