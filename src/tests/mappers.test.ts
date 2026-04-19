import './fix-env'
import fs from 'fs/promises'
import path from 'path'

import { mapMessage } from '../mappers'
import swiftServer from '../SwiftServer/lib'

type MapMessageFixture = Parameters<typeof mapMessage>

async function testMessageMapFixture(fixturePath: string) {
  const pathRelativeToTests = path.join(__dirname, fixturePath)

  test(path.basename(fixturePath), async () => {
    const parameters = JSON.parse(await fs.readFile(pathRelativeToTests, 'utf8')) as MapMessageFixture
    expect(parameters).toHaveLength(5)

    type Row = typeof parameters[0]
    type MessageRowBufferKeys = { [Key in keyof Row]: Row[Key] extends Buffer ? Key : never }[keyof Row]

    // To represent `MessageRow`'s `Buffer` properties in JSON, interpret them
    // from Base64-encoded strings.
    const fixupDataUri = (key: MessageRowBufferKeys) => {
      if (!key || !(key in parameters[0])) return

      // Slice off "data:;base64,".
      parameters[0][key] = Buffer.from((parameters[0][key] as unknown as string).slice(13), 'base64')
    }

    fixupDataUri('attributedBody')
    fixupDataUri('message_summary_info')

    parameters[1] ??= []
    parameters[2] ??= []

    const message = mapMessage(...parameters)
    message.forEach(m => delete m._original)
    expect(message).toMatchSnapshot()
  })
}

describe('multi part messages', () => {
  ['./fixture1.json', './fixture2.json'].forEach(testMessageMapFixture)
})

describe('partially unsending messages', () => {
  [
    './partial_leading_unsends.json',
    './partial_trailing_unsends.json',
    './partial_multiple_middle_adjacent_unsend.json',
  ].forEach(testMessageMapFixture)
})

describe('inline stickers', () => {
  test('maps inline sticker fragments as one message', async () => {
    const fixturePath = path.join(__dirname, './fixture2.json')
    const parameters = JSON.parse(await fs.readFile(fixturePath, 'utf8')) as MapMessageFixture

    parameters[0].attributedBody = Buffer.from('inline-sticker')
    parameters[1] = [{
      ...parameters[1]![0],
      attachmentID: '490F439B-DCFE-4828-A2A0-9A67A45EB9AA',
      fileName: '3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F.heic',
      filePath: '/Users/kb/Library/Messages/StickerCache/52cad24171c596d6-3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F/3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F.heic',
      filename: '~/Library/Messages/StickerCache/52cad24171c596d6-3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F/3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F.heic',
      transfer_name: '3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F.heic',
      ext: 'heic',
      total_bytes: 15131,
      is_sticker: 1,
    }]
    parameters[2] = []

    const decodeSpy = jest.spyOn(swiftServer, 'decodeAttributedString').mockReturnValue([
      { from: 0, to: 6, text: 'asdas ', attributes: { __kIMMessagePartAttributeName: '0' } },
      {
        from: 6,
        to: 7,
        text: '\uFFFC',
        attributes: {
          __kIMEmojiImageAttributeName: '1',
          __kIMFileTransferGUIDAttributeName: '490F439B-DCFE-4828-A2A0-9A67A45EB9AA',
          __kIMMessagePartAttributeName: '0',
        },
      },
      { from: 7, to: 14, text: ' asdasd', attributes: { __kIMMessagePartAttributeName: '0' } },
    ])

    const message = mapMessage(...parameters)
    decodeSpy.mockRestore()

    expect(message).toHaveLength(1)
    expect(message[0]).toMatchObject({
      id: '829D7284-F1C6-4848-B7C7-C4190EA416BD',
      text: 'asdas \uFFFC asdasd',
      textAttributes: {
        entities: [{
          from: 6,
          to: 7,
          replaceWithMedia: {
            mediaType: 'img',
            srcURL: 'file:///Users/kb/Library/Messages/StickerCache/52cad24171c596d6-3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F/3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F.heic',
          },
        }],
      },
    })
    expect(message[0].attachments).toBeUndefined()
    expect(message[0].extra?.part).toBeUndefined()
  })

  test('maps sticker-only messages as attachments', async () => {
    const fixturePath = path.join(__dirname, './fixture2.json')
    const parameters = JSON.parse(await fs.readFile(fixturePath, 'utf8')) as MapMessageFixture

    parameters[0].attributedBody = Buffer.from('sticker-only')
    parameters[1] = [{
      ...parameters[1]![0],
      attachmentID: 'CC944B43-86EB-4F86-A58D-14C9B7C27356',
      fileName: '3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F.heic',
      filePath: '/Users/kb/Library/Messages/StickerCache/52cad24171c596d6-3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F/3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F.heic',
      filename: '~/Library/Messages/StickerCache/52cad24171c596d6-3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F/3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F.heic',
      transfer_name: '3B4DEFE1-285E-47D9-89AF-BA1BF7E0F72F.heic',
      ext: 'heic',
      total_bytes: 15131,
      is_sticker: 1,
      size: { width: 320, height: 320 },
    }]
    parameters[2] = []

    const decodeSpy = jest.spyOn(swiftServer, 'decodeAttributedString').mockReturnValue([
      {
        from: 0,
        to: 1,
        text: '\uFFFC',
        attributes: {
          __kIMEmojiImageAttributeName: '1',
          __kIMFileTransferGUIDAttributeName: 'CC944B43-86EB-4F86-A58D-14C9B7C27356',
          __kIMMessagePartAttributeName: '0',
        },
      },
    ])

    const message = mapMessage(...parameters)
    decodeSpy.mockRestore()

    expect(message).toHaveLength(1)
    expect(message[0]).toMatchObject({
      id: '829D7284-F1C6-4848-B7C7-C4190EA416BD',
      attachments: [{
        id: 'CC944B43-86EB-4F86-A58D-14C9B7C27356',
        isSticker: true,
        type: 'img',
      }],
    })
    expect(message[0].text).toBeUndefined()
    expect(message[0].textAttributes).toBeUndefined()
  })
})
