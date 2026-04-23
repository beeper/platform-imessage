import { app } from 'electron'
import * as path from 'node:path'
import * as fs from 'node:fs/promises'
import { inspect } from 'node:util'
import readline from 'node:readline/promises'
import { setTimeout as sleep } from 'node:timers/promises'
// eslint-disable-next-line import/no-extraneous-dependencies
import c from 'ansi-colors'
import swiftServer, { MESSAGES_CONTROLLER_METHOD_NAMES, MessagesController } from '../../SwiftServer/lib/index'
import { getLastMessageID } from './last-message'
import { runStress } from './stress'
import { measure } from './util'
/* eslint-disable no-inner-declarations */

swiftServer.isLoggingEnabled = true
const state: { mc: MessagesController | null } = { mc: null }

const completer: readline.Completer = linePartial => {
  const { mc } = state
  if (!mc) return [[], linePartial]
  const hits = MESSAGES_CONTROLLER_METHOD_NAMES.filter(key => key.startsWith(linePartial))
  return [hits, linePartial]
}

const historyFilePath = path.resolve(import.meta.dirname, '.messages-controller-cli.history.json')
const readHistory = async (): Promise<string[]> => JSON.parse(await fs.readFile(historyFilePath, 'utf8'))
const writeHistory = (history: string[]): Promise<void> => fs.writeFile(historyFilePath, JSON.stringify(history))
const KEEP_ALIVE_FLAG = '--stay-open'
const LAST_MESSAGE_ARG = 'last-message'

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  historySize: 1_000,
  tabSize: 2,
  history: await readHistory().catch(() => []),
  completer,
})

rl.on('history', history => {
  setTimeout(() => {
    writeHistory(history)
  }, 0)
})

const LAST_MESSAGE_ARG_INDEX_BY_COMMAND: Record<string, number | undefined> = {
  undoSend: 1,
  editMessage: 1,
  setReaction: 1,
  sendMessage: 3,
}

async function resolveMagicArgs(command: string, args: string[]): Promise<string[]> {
  const position = args.indexOf(LAST_MESSAGE_ARG)
  if (position === -1) return args

  const expected = LAST_MESSAGE_ARG_INDEX_BY_COMMAND[command]
  if (expected !== position) {
    throw new Error(`${LAST_MESSAGE_ARG} is not supported at argument ${position + 1} for ${command}`)
  }

  const threadID = args[0]
  if (!threadID) throw new Error(`${LAST_MESSAGE_ARG} requires a thread ID`)

  const resolved = [...args]
  resolved[position] = await getLastMessageID(threadID)
  return resolved
}

async function main() {
  const { messagesControllerClass } = swiftServer
  console.log(c.bold.blue('creating messages controller'))
  const [mc, creationLatency] = await measure(messagesControllerClass.create)
  state.mc = mc
  console.log(c.bold.green(`messages controller created in ${creationLatency.toFixed(3)}ms`))

  async function call<K extends keyof MessagesController>(methodName: K, ...args: Parameters<MessagesController[K]>): Promise<ReturnType<MessagesController[K]>> {
    const id = crypto.randomUUID()

    console.log(c.bold.cyan(`[${id}] 📤 [${methodName}] with:`), ...args)

    function printResult(result: unknown, status: string, latency: number) {
      const inspection = inspect(result, { colors: true })
      console.log(
        c.bold.cyan(
          `[${id}] 📩 [${methodName}] ${status}: ${inspection} in ${latency.toFixed(
            3,
          )}ms`,
        ),
      )
    }

    const method = mc[methodName] as (...args0: Parameters<MessagesController[K]>) => Promise<ReturnType<MessagesController[K]>>
    const beforeCalling = performance.now()
    try {
      const result = await method.apply(mc, args)
      printResult(result, '✅ resolved', performance.now() - beforeCalling)
      return result
    } catch (error) {
      printResult(error, '🚫 rejected', performance.now() - beforeCalling)
      throw error
    }
  }

  async function watch(id: string) {
    await call('watchThreadActivity', id, statuses => {
      console.log(c.bold.cyan('thread activity:'), statuses)
    })
  }

  async function run(input: string): Promise<void> {
    const [command, ...rawArgs] = input.split(' ')
    const args = await resolveMagicArgs(command, rawArgs)

    switch (command) {
      case 'stress': {
        if (args.length < 2) {
          console.log(c.bold.red('stress requires two thread IDs'))
          break
        }
        console.log(c.bold.green('stressing...'))
        await runStress(mc, args[0], args[1])
        console.log(c.bold.cyan('done!'))
        break
      }
      case 'watch': {
        if (!args.length) {
          console.log(c.bold.red('watch command requires a thread ID'))
          break
        }
        await watch(args[0])
        break
      }
      default: {
        if (command === '') {
          break
        }

        const method = mc[command as keyof MessagesController]
        if (!method || !(method instanceof Function)) {
          console.log(c.bold.red(`no such command or MessagesController method: "${command}"`))
          break
        }

        // doesn't seem to actually work for native methods, but leaving in for correctness sake
        if (args.length < method.length) {
          console.error(c.bold.red(`⌨️ ⚠️ ${c.blue(command)} requires ${method.length} arguments (passed ${args.length})`))
          break
        }

        const before = performance.now()
        try {
          const bound = (method as Function).bind(mc) as (...arg: unknown[]) => unknown
          const transformed: unknown[] = args.map(arg => {
            if (arg === '_') return undefined
            if (arg === 'true') return true
            if (arg === 'false') return false
            if (arg === 'undefined') return undefined
            if (arg === 'null') return null
            return arg.replaceAll('%date%', new Date().toLocaleString())
          })
          const result = await bound(...transformed)
          const latency = performance.now() - before
          console.error(c.bold.green(`⌨️ ✅ MessagesController#${c.blue(command)} interactive call OK (took ${latency.toFixed(3)}ms):`), result)
        } catch (error) {
          const latency = performance.now() - before
          console.error(c.bold.red(`⌨️ ❌ MessagesController#${c.blue(command)} interactive call FAILED (took ${latency.toFixed(3)}ms):`), error)
        }
        break
      }
    }
  }

  const cliArgs = process.argv.slice(2)
  if (cliArgs.length > 0) {
    const keepAliveRequested = cliArgs.includes(KEEP_ALIVE_FLAG)
    const commandArgs = cliArgs.filter(arg => arg !== KEEP_ALIVE_FLAG)
    const cliCommand = commandArgs.join(' ')
    await run(cliCommand)
    const commandName = commandArgs[0]
    const shouldKeepAlive = keepAliveRequested
      || commandName === 'watch'
      || commandName === 'watchThreadActivity'
    if (!shouldKeepAlive) {
      await sleep(1000)
      mc.dispose()
      process.exit()
    }
  }

  const running = true
  while (running) {
    const prompt = c.bold('imsg> ')
    const input = await rl.question(prompt)

    if (/^(q|quit|exit)$/.test(input)) {
      mc.dispose()
      process.exit()
    } else {
      await run(input.trim())
    }
  }
}

const announceError = (error: unknown, kind = 'exception') => {
  const banner = () => {
    console.log()
    console.log('🚨'.repeat(40))
    console.log()
  }

  banner()
  const stringed = String(error)
  console.error(c.inverse.bold.red(`❌ UNCAUGHT ${kind}:`.toUpperCase()), c.bold.red(stringed))
  banner()
}

process.on('uncaughtException', error => {
  announceError(error)
})

process.on('unhandledRejection', error => {
  announceError(error, 'rejection')
})

app.whenReady().then(async () => {
  try {
    await main()
  } catch (err) {
    announceError(err, 'exception (in main)')
    process.exit(1)
  }
})
