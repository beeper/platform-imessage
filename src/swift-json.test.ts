import { parseSwiftMessageAPIJSON, reviveSwiftMessageAPIValue } from './swift-json'

describe('swift-json', () => {
  it('converts message date fields in parsed JSON', () => {
    const parsed = parseSwiftMessageAPIJSON<{
      timestamp: Date
      editedTimestamp: Date
      seen: Date
      sortKey: number
    }>(JSON.stringify({
      timestamp: 1,
      editedTimestamp: 2,
      seen: 3,
      sortKey: 4,
    }))

    expect(parsed.timestamp).toEqual(new Date(1))
    expect(parsed.editedTimestamp).toEqual(new Date(2))
    expect(parsed.seen).toEqual(new Date(3))
    expect(parsed.sortKey).toBe(4)
  })

  it('converts event date fields in already-parsed Swift values', () => {
    const revived = reviveSwiftMessageAPIValue({
      entries: [{
        id: 'message-id',
        timestamp: 1,
        editedTimestamp: 2,
        seen: {
          alice: 3,
          bob: true,
        },
        sortKey: 4,
      }],
    })

    expect(revived.entries[0].timestamp).toEqual(new Date(1))
    expect(revived.entries[0].editedTimestamp).toEqual(new Date(2))
    expect(revived.entries[0].seen).toEqual({
      alice: new Date(3),
      bob: true,
    })
    expect(revived.entries[0].sortKey).toBe(4)
  })

  it('mutates already-parsed Swift values while reviving', () => {
    const event = {
      entries: [{
        timestamp: 1,
        seen: { alice: 2 },
      }],
    }

    const revived = reviveSwiftMessageAPIValue(event)

    expect(revived).toBe(event)
    expect(event.entries[0].timestamp).toEqual(new Date(1))
    expect(event.entries[0].seen.alice).toEqual(new Date(2))
    expect(revived.entries[0].timestamp).toEqual(new Date(1))
    expect(revived.entries[0].seen.alice).toEqual(new Date(2))
  })
})
