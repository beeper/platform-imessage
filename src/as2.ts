import childProcess from 'child_process'
import pRetry from 'p-retry'
import { setTimeout as setTimeoutAsync } from 'timers/promises'
import { texts } from '@textshq/platform-sdk'

import { IS_BIG_SUR_OR_UP, MESSAGES_APP_BUNDLE_ID } from './constants'
import spawnASServer from './as-server'
import IS_DEV_ENVIRON from './is-dev-environ'

enum ScriptName {
  IS_MESSAGES_VISIBLE = 'is-messages-visible',
  IS_MESSAGES_RUNNING = 'is-messages-running',
  HIDE_MESSAGES = 'hide-messages',
  HIDE_MESSAGES_BEHIND_TEXTS = 'hide-messages-behind-texts',
  SEND_TEXT = 'send-text',
  SEND_FILE = 'send-file',
  ASK_FOR_AUTOMATION = 'ask-for-automation',
  CREATE_THREAD = 'create-thread',
  SELECT_FIRST_N_THREADS = 'select-first-n-threads',
}

const RETRY_OPTIONS: pRetry.Options = {
  retries: 1,
  minTimeout: 10,
  maxRetryTime: 10_000,
  onFailedAttempt: error => {
    texts.Sentry.captureException(error)
    console.error(error)
  },
}

export const OSAError = {
  // {
  //   NSLocalizedDescription = "Error: Error: Can not send message to a chat you are not a member of!";
  //   NSLocalizedFailureReason = "Error: Error: Can not send message to a chat you are not a member of!";
  //   OSAScriptErrorBriefMessageKey = "Error: Error: Can not send message to a chat you are not a member of!";
  //   OSAScriptErrorMessageKey = "Error: Error: Can not send message to a chat you are not a member of!";
  //   OSAScriptErrorNumberKey = 1;
  //   OSAScriptErrorRangeKey = "NSRange: {0, 0}";
  // }
  // {
  //   NSLocalizedDescription = "Error: Error: Application isn't running.";
  //   NSLocalizedFailureReason = "Error: Error: Application isn't running.";
  //   OSAScriptErrorBriefMessageKey = "Error: Error: Application isn't running.";
  //   OSAScriptErrorMessageKey = "Error: Error: Application isn't running.";
  //   OSAScriptErrorNumberKey = "-600";
  //   OSAScriptErrorRangeKey = "NSRange: {0, 0}";
  // }
  // {
  //   NSLocalizedDescription = "Error: Error: Connection is invalid."
  //   NSLocalizedFailureReason = "Error: Error: Connection is invalid."
  //   OSAScriptErrorBriefMessageKey = "Error: Error: Connection is invalid."
  //   OSAScriptErrorMessageKey = "Error: Error: Connection is invalid."
  //   OSAScriptErrorNumberKey = "-609"
  //   OSAScriptErrorRangeKey = "NSRange: {0, 0}"
  // }
  // {
  //   NSLocalizedDescription = "Error: Error: AppleEvent timed out.";
  //   NSLocalizedFailureReason = "Error: Error: AppleEvent timed out.";
  //   OSAScriptErrorBriefMessageKey = "Error: Error: AppleEvent timed out.";
  //   OSAScriptErrorMessageKey = "Error: Error: AppleEvent timed out.";
  //   OSAScriptErrorNumberKey = "-1712";
  //   OSAScriptErrorRangeKey = "NSRange: {0, 0}";
  // }
  // {
  //   NSLocalizedDescription = "Error: Error: An error occurred."
  //   NSLocalizedFailureReason = "Error: Error: An error occurred."
  //   OSAScriptErrorBriefMessageKey = "Error: Error: An error occurred."
  //   OSAScriptErrorMessageKey = "Error: Error: An error occurred."
  //   OSAScriptErrorNumberKey = "-1743"
  //   OSAScriptErrorRangeKey = "NSRange: {0, 0}"
  // }
  CantSendMessageToChatYouReNotMemberOf: 1,
  AppIsntRunning: -600,
  ConnectionInvalid: -609,
  AppleEventTimedOut: -1712,
  CantGetObject: -1728,
  AnErrorOccurred: -1743,
}

function createAPIServer() {
  const { run, exit } = spawnASServer()

  const isMessagesRunning = () =>
    run(ScriptName.IS_MESSAGES_RUNNING)
      .then(str => str === 'true')

  const isMessagesVisible = () =>
    run(ScriptName.IS_MESSAGES_VISIBLE)
      .then(() => true)
      .catch(() => false)

  const hideMessages = () =>
    run(ScriptName.HIDE_MESSAGES)

  const sendText = (...args: any[]) =>
    run(ScriptName.SEND_TEXT, [JSON.stringify(args)])

  const sendFile = (...args: any[]) =>
    run(ScriptName.SEND_FILE, [JSON.stringify(args)])

  let spawnedMessagesApp = false
  const ensureMessagesAppRunning = async () => {
    const running = await isMessagesRunning()
    if (running) return
    spawnedMessagesApp = true
    console.log('opening Messages.app')
    childProcess.spawn('/usr/bin/open', ['-gjb', MESSAGES_APP_BUNDLE_ID])
    await setTimeoutAsync(200)
  }

  const dispose = () => {
    exit()
    if (spawnedMessagesApp) {
      childProcess.spawn('/usr/bin/killall', ['Messages'])
    }
  }

  const hideMessagesBehindTexts = () =>
    run(ScriptName.HIDE_MESSAGES_BEHIND_TEXTS, [IS_DEV_ENVIRON ? 'Electron' : 'Texts'])

  const newThread = (participants: string[]) =>
    run(ScriptName.CREATE_THREAD, [
      participants.map(x => `participant "${x}"`).join(','),
      participants.map(x => `buddy "${x}" of imsgService`).join(','),
    ])

  const hideMessagesAppTimeout: NodeJS.Timeout = null
  function hideMessagesAppAfterDelay() {
    if (hideMessagesAppTimeout) clearTimeout(hideMessagesAppTimeout)
    setTimeout(() => hideMessages(), 400)
    setTimeout(() => hideMessages(), 800)
  }

  async function wrapHideIfNotVisible(cb: Function) {
    if (IS_BIG_SUR_OR_UP) return cb()
    const isVisible = await isMessagesVisible()
    hideMessagesBehindTexts()
    const result = await cb()
    if (!isVisible) hideMessagesAppAfterDelay()
    return result
  }

  return {
    async askForAutomationAccess() {
      try {
        await run(ScriptName.ASK_FOR_AUTOMATION)
        if (!IS_BIG_SUR_OR_UP) await run(ScriptName.IS_MESSAGES_VISIBLE)
        return true
      } catch {
        return false
      }
    },
    async sendTextMessage(threadID: string, text: string) {
      await ensureMessagesAppRunning()
      await pRetry(
        () => sendText(threadID, text, threadID.split(';').pop()),
        RETRY_OPTIONS,
      )
    },
    async sendFile(threadID: string, filePath: string) {
      await ensureMessagesAppRunning()
      await wrapHideIfNotVisible(() => pRetry(
        () => sendFile(threadID, filePath, threadID.split(';').pop()),
        RETRY_OPTIONS,
      ))
    },
    async createThread(participants: string[]) {
      await ensureMessagesAppRunning()
      return wrapHideIfNotVisible(async () => {
        const threadID = await newThread(participants) // text chat id iMessage;-;XYZ
        return threadID
      })
    },
    dispose,
  }
}

export default createAPIServer
