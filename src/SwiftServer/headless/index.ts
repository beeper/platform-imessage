import { app } from 'electron'
import * as path from 'node:path'
import * as fs from 'node:fs/promises'
import { inspect } from 'node:util'
import { readFile } from 'node:fs/promises'
import readline from 'node:readline/promises'
// eslint-disable-next-line import/no-extraneous-dependencies
import c from 'ansi-colors'
// eslint-disable-next-line import/no-extraneous-dependencies
import * as z from 'zod'
import swiftServer, { messageControllerDebuggingAvailable, MESSAGES_CONTROLLER_METHOD_NAMES, MessagesController, MessagesControllerDebugging } from '../lib/index'
import { measure } from './util'
/* eslint-disable no-inner-declarations */

const Config = z.object({
  guids: z.object({
    first: z.string(),
    second: z.string(),
    watching: z.string().optional(),
  }),
})

swiftServer.isLoggingEnabled = true
const state: { mc: MessagesController | null } = { mc: null }

const completer: readline.Completer = linePartial => {
  const { mc } = state
  if (!mc) return [[], linePartial]
  const hits = MESSAGES_CONTROLLER_METHOD_NAMES.filter(key => key.startsWith(linePartial))
  return [hits, linePartial]
}

const historyFilePath = path.resolve(import.meta.dirname, '.headless-history.json')
const readHistory = async (): Promise<string[]> => JSON.parse(await fs.readFile(historyFilePath, 'utf8'))
const writeHistory = (history: string[]): Promise<void> => fs.writeFile(historyFilePath, JSON.stringify(history))

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

async function main() {
  let config: z.infer<typeof Config>
  try {
    const text = await readFile('./headless-config.json', 'utf8')
    config = Config.parse(JSON.parse(text))
  } catch (error) {
    throw new Error("can't load config", { cause: error })
  }

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
    const [command, ...args] = input.split(' ')

    switch (command) {
      case 'stress': {
        console.log(c.bold.green('stressing...'))
        await Promise.all([
          call('toggleThreadRead', config.guids.first, true),
          call('toggleThreadRead', config.guids.first, true),
          call('toggleThreadRead', config.guids.second, true),
          call('toggleThreadRead', config.guids.first, true),
          call('toggleThreadRead', config.guids.second, true),
          call('toggleThreadRead', config.guids.first, true),
          call('toggleThreadRead', config.guids.second, true),
          call('toggleThreadRead', config.guids.first, true),
          call('toggleThreadRead', config.guids.first, true),
          call('toggleThreadRead', config.guids.first, true),
          call('toggleThreadRead', config.guids.first, true),
        ])
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

  const cliCommands = process.argv.slice(2)
  for (const command of cliCommands) {
    await run(command)
  }
  if (config.guids.watching) await watch(config.guids.watching)

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
