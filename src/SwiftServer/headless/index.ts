import { app } from 'electron'
import { inspect } from 'node:util'
import { readFile } from 'node:fs/promises'
import readline from 'node:readline/promises'
// eslint-disable-next-line import/no-extraneous-dependencies
import c from 'ansi-colors'
// eslint-disable-next-line import/no-extraneous-dependencies
import * as z from 'zod'
import swiftServer, { MessagesController } from '../lib/index'
import { measure } from './util'
/* eslint-disable no-inner-declarations */

const Config = z.object({
  guids: z.object({
    first: z.string(),
    second: z.string(),
  }),
})

swiftServer.isLoggingEnabled = true

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
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

  async function run(command: string): Promise<void> {
    if (command === 'stress') {
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
    }
  }

  const cliCommands = process.argv.slice(2)
  for (const command of cliCommands) {
    await run(command)
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

app.whenReady().then(async () => {
  try {
    await main()
  } catch (err) {
    // don't let electron catch the error because it'll display it in a dialog
    // which you have to dismiss manually, and it's super annoying
    console.error(c.bold.red('uncaught exception:'), err)
    process.exit(1)
  }
})
