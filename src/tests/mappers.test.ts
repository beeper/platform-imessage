import './fix-env'
import fs from 'fs/promises'
import path from 'path'

import { mapMessage } from '../mappers'

async function testMessageMapFixture(fixturePath: string) {
  const pathRelativeToTests = path.join(__dirname, fixturePath)

  test(path.basename(fixturePath), async () => {
    const parameters: Parameters<typeof mapMessage> = JSON.parse(await fs.readFile(pathRelativeToTests, 'utf8'))

    const fixupDataUri = (key: string) => {
      if (key in parameters[0]) {
        // Slice off "data:;base64," present in test fixtures.
        parameters[0][key] = Buffer.from(parameters[0][key].slice(13), 'base64')
      }
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
