import path from 'path'
import readline from 'readline'
import fs from 'fs/promises'
import swiftServer, { MessagesController } from './lib/index'

function prompt(query: string) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  })
  return new Promise<string>(resolve => {
    rl.question(query, answer => {
      resolve(answer)
      rl.close()
    })
  })
}

swiftServer.isLoggingEnabled = true
const { messagesControllerClass } = swiftServer
let mc: MessagesController
async function main() {
  // const buf = await fs.readFile(process.argv[2])
  // console.log(swiftServer.decodeAttributedString(buf))
  mc = await messagesControllerClass.create()
  // console.log(await mc.isValid())
  // await mc.notifyAnyway('iMessage;-;kb24x7@gmail.com')
  // await mc.markRead('2A077AC2-AD53-46F8-ABBB-D82EF6D3D2BF')
  // await mc.setReaction('FEDED224-E379-4AC5-A6B9-09973F21E3C7', 0, 'laugh', true, true)
  // await mc.setReaction('1617F5D1-E661-46C9-A09D-724BB47BEF86', 0, 'laugh', true, false)
  // await mc.sendReply('iMessage;-;kb24x7@gmail.com', 'B391D825-7316-4268-85DE-67F9533ADC52', 0, '', '', true, '', '/Users/kb/Desktop/Screen Shot 2022-02-09 at 10.15.10 PM.png')
  // await mc.sendMessage('iMessage;-;kb24x7@gmail.com', undefined, '/Users/kb/Desktop/party-parrot.gif', undefined)
  await mc.editMessage('iMessage;-;kishan24x7@gmail.com', JSON.stringify({
    messageGUID: 'BF5C0102-04D0-42E0-8449-BEDB234F3A7D',
    offset: 0,
    cellID: null,
    cellRole: null,
    overlay: false,
  }), 'new text6: ' + Math.random())
  // await mc.setReaction('0367450D-F385-4561-AD28-9670FDFCD8BE', 0, 'com.apple.messages.URLBalloonProvider', '', true, 'laugh', true)
  // await mc.sendReply('0367450D-F385-4561-AD28-9670FDFCD8BE', 0, 'asd', '', true, `testing ${Math.random()} ${new Date()}`)
  // await mc.watchThreadActivity('kb24x7@gmail.com', status => {
  //   console.log(status)
  // })
  // await mc.markRead('F8C3DBB1-9FB0-1183-A0A7-70FCA8E3E6C9')
  // await mc.markRead('8C9D7F10-E961-4FD6-BD67-54F18767E582')
  // await prompt('do it again?')
  // await mc.markRead('8C9D7F10-E961-4FD6-BD67-54F18767E582')
  // await mc.setReaction('FEDED224-E379-4AC5-A6B9-09973F21E3C7', 0, 'laugh', true, true)
  // await mc.setReaction('1617F5D1-E661-46C9-A09D-724BB47BEF86', 0, 'laugh', true, false)
  // await mc.sendReply('4AF9C619-210E-4A52-B92E-45E709563F36', 'testing ' + Math.random(), true)
  // await mc.sendReply('1617F5D1-E661-46C9-A09D-724BB47BEF86', 'testing ' + Math.random(), true)
  console.log('done')
  process.stdin.read()
  // await mc.dispose()
  // process.exit()
}
main()

process.on('uncaughtException', err => {
  console.error('uncaughtException', err)
})
process.on('unhandledRejection', err => {
  console.error('unhandledRejection', err)
})
