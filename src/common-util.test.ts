import { isSelectable, canQuoteMessage, canReactMessage } from './common-util'
import { BeeperMessage } from './desktop-types'

const msg = (partial: Partial<BeeperMessage>): BeeperMessage =>
  ({ id: '1', threadID: 't', sortKey: 0, ...partial } as BeeperMessage)

const plainText = msg({ text: 'hello' })
const emojiOnly = msg({ text: '😀' })
const attachment = msg({ text: 'caption', attachments: [{} as any] })
const linkMessage = msg({ text: 'see this', links: [{} as any] })
const noText = msg({ text: null as any })
const linkedPlain = msg({ text: 'hi', linkedMessageID: 'abc' })
const linkedEmoji = msg({ text: '😀', linkedMessageID: 'abc' })

describe('isSelectable', () => {
  test('text-only messages are selectable', () => {
    expect(isSelectable(plainText)).toBe(true)
  })

  test('emoji-only / attachment / link / textless messages are not selectable', () => {
    expect(isSelectable(emojiOnly)).toBe(false)
    expect(isSelectable(attachment)).toBe(false)
    expect(isSelectable(linkMessage)).toBe(false)
    expect(isSelectable(noText)).toBe(false)
  })
})

describe('canQuoteMessage', () => {
  test('Monterey+ allows quoting anything (undefined sentinel = always allowed)', () => {
    expect(canQuoteMessage(true)).toBeUndefined()
  })

  test('pre-Monterey falls back to isSelectable', () => {
    expect(canQuoteMessage(false)).toBe(isSelectable)
  })
})

describe('canReactMessage', () => {
  test('Monterey+: any non-linked message is reactable (p:N/ deep link selects it)', () => {
    const canReact = canReactMessage(true)
    expect(canReact(plainText)).toBe(true)
    expect(canReact(emojiOnly)).toBe(true)
    expect(canReact(attachment)).toBe(true)
  })

  test('Monterey+: linked messages are reactable only when selectable', () => {
    const canReact = canReactMessage(true)
    expect(canReact(linkedPlain)).toBe(true)
    expect(canReact(linkedEmoji)).toBe(false)
  })

  test('pre-Monterey: react requires a selectable message regardless of linking', () => {
    const canReact = canReactMessage(false)
    expect(canReact(plainText)).toBe(true)
    expect(canReact(emojiOnly)).toBe(false)
    expect(canReact(attachment)).toBe(false)
    expect(canReact(linkedPlain)).toBe(true)
    expect(canReact(linkedEmoji)).toBe(false)
  })
})
