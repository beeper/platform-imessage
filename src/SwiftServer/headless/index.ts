import readline from 'node:readline/promises'
// eslint-disable-next-line import/no-extraneous-dependencies
import c from 'ansi-colors'
import swiftServer, { MessagesController } from '../lib/index'
import { measure } from './util'

swiftServer.isLoggingEnabled = true

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
})

const { messagesControllerClass } = swiftServer
console.log(c.bold.blue('creating messages controller'))
const [mc, duration] = await measure(messagesControllerClass.create)
console.log(c.bold.green(`messages controller created in ${duration.toFixed(3)}ms`))

const running = true
while (running) {
  const prompt = c.bold('imsg> ')
  const input = await rl.question(prompt)
  console.log(input)
}
