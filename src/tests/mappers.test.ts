import './fix-env'
import { mapMessage } from '../mappers'
import fixture1 from './fixture1.json'
import fixture2 from './fixture2.json'

describe('multi part messages', () => {
  [fixture1, fixture2].forEach((f: any, i) => {
    test(String(i), () => {
      const msg = mapMessage(f[0], f[1], f[2], f[3])
      msg.forEach(m => delete m._original)
      expect(msg).toMatchSnapshot()
    })
  })
})
