import path from 'path'
import fs from 'fs/promises'
import swiftServer from './lib/index'

(async () => {
  swiftServer.isLoggingEnabled = true
  // const buf = await fs.readFile(process.argv[2])
  // console.log(swiftServer.decodeAttributedString(buf))
  const { messagesControllerClass } = swiftServer
  const mc = await messagesControllerClass.create()
  console.log(await mc.isValid())
  // await mc.watchThreadActivity('kb24x7@gmail.com', status => {
  //   console.log(status)
  // })
  // await mc.markRead('F8C3DBB1-9FB0-1183-A0A7-70FCA8E3E6C9')
  await mc.markRead('8C9D7F10-E961-4FD6-BD67-54F18767E582')
  // await mc.setReaction('FEDED224-E379-4AC5-A6B9-09973F21E3C7', 0, 'laugh', true, true)
  // await mc.setReaction('1617F5D1-E661-46C9-A09D-724BB47BEF86', 0, 'laugh', true, false)
  // await mc.sendReply('4AF9C619-210E-4A52-B92E-45E709563F36', 'testing ' + Math.random(), true)
  // await mc.sendReply('1617F5D1-E661-46C9-A09D-724BB47BEF86', 'testing ' + Math.random(), true)
  console.log('done')
  // await mc.dispose()
  // process.exit()
})()

process.on('uncaughtException', err => {
  console.error('uncaughtException', err)
})
process.on('unhandledRejection', err => {
  console.error('unhandledRejection', err)
})
