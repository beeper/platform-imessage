import '../src/tests/fix-env'

import { swiftMapperReviver } from '../src/swift-json'
import {
  diffParityValues,
  normalizeParityValue,
} from './parity-diff.cjs'

describe('mapper parity helpers', () => {
  test('normalizes dates and ignores _original', () => {
    const swift = normalizeParityValue([{ id: 'm1', timestamp: new Date(1000) }])
    const typescript = normalizeParityValue([{ id: 'm1', timestamp: new Date(1000), _original: 'debug' }])

    expect(diffParityValues(swift, typescript)).toEqual([])
  })

  test('treats absent and undefined fields as equal after normalization', () => {
    const swift = normalizeParityValue([{ id: 'm1' }])
    const typescript = normalizeParityValue([{ id: 'm1', seen: undefined }])

    expect(diffParityValues(swift, typescript)).toEqual([])
  })

  test('reports divergent paths without values', () => {
    const swift = normalizeParityValue([{ id: 'm1', text: 'new' }])
    const typescript = normalizeParityValue([{ id: 'm1', text: 'old' }])

    expect(diffParityValues(swift, typescript)).toEqual([
      { path: '$[0].text', kind: 'value' },
    ])
  })

  test('revives swift date fields from milliseconds', () => {
    const revived = JSON.parse(
      JSON.stringify([{ timestamp: 1000, seen: 2000, editedTimestamp: 3000 }]),
      swiftMapperReviver,
    )

    expect(revived).toEqual([{ timestamp: new Date(1000), seen: new Date(2000), editedTimestamp: new Date(3000) }])
  })
})
