import './fix-env'
import { mapMessage } from '../mappers'
import fixture1 from './fixture1.json'
import fixture2 from './fixture2.json'

describe('multi part messages', () => {
  [fixture1, fixture2].forEach((f: any, i) => {
    test(String(i), () => {
      const fixupDataUris = (object, key) => {
        if (key in object) {
          // Slice off "data:;base64," present in test fixtures.
          object[key] = Buffer.from(object[key].slice(13), 'base64')
        }
      }

      fixupDataUris(f[0], 'attributedBody')
      fixupDataUris(f[0], 'message_summary_info')
      const msg = mapMessage(f[0], f[1], f[2], f[3])
      msg.forEach(m => delete m._original)
      expect(msg).toMatchSnapshot()
    })
  })
})
