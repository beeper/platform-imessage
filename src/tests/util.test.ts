import './fix-env'

import { stringifyWithArrayBuffers } from '../util'

describe('stringifyWithArrayBuffers', () => {
  test('serializes Buffer values as data URIs', () => {
    expect(stringifyWithArrayBuffers({ payload: Buffer.from('hello') }))
      .toBe('{"payload":"data:;base64,aGVsbG8="}')
  })

  test('serializes typed array values as data URIs', () => {
    expect(stringifyWithArrayBuffers({ payload: new Uint8Array([104, 105]) }))
      .toBe('{"payload":"data:;base64,aGk="}')
  })
})
