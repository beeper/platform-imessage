import { coverPendingSentMessages, MessageSendState, nextCoverageCheckDelay, normalizeSentAt, PENDING_SENT_MESSAGES_MAX_AGE_MS } from './archive-coverage'
import { ThreadArchivalState } from './persistence'
import { appleDateToMillisSinceEpoch, makeAppleDate } from './time'

const T = 1_788_951_362_000

const state = (id: string, partial: Partial<MessageSendState> = {}): MessageSendState =>
  ({ id, sentAt: T - 1_000, isSent: true, isErrored: false, ...partial })

const archive = (archivedAt: number, pending?: string[]): ThreadArchivalState =>
  ({ archivedAt: makeAppleDate(new Date(archivedAt)), ...(pending ? { pendingSentMessageIDs: pending } : {}) })

const cutoff = (a: ThreadArchivalState) => appleDateToMillisSinceEpoch(a.archivedAt)

describe('normalizeSentAt', () => {
  test('keeps finite numbers only', () => {
    expect(normalizeSentAt(T)).toBe(T)
    expect(normalizeSentAt(NaN)).toBeNull()
    expect(normalizeSentAt(null)).toBeNull()
    expect(normalizeSentAt(new Date(T))).toBeNull()
  })
})

describe('nextCoverageCheckDelay', () => {
  test('looks often at first, then rarely, then stops', () => {
    expect(nextCoverageCheckDelay(T, T)).toBe(1_000)
    expect(nextCoverageCheckDelay(T, T + 29_000)).toBe(1_000)
    expect(nextCoverageCheckDelay(T, T + 30_000)).toBe(5_000)
    expect(nextCoverageCheckDelay(T, T + 2 * 60_000)).toBe(60_000)
    expect(nextCoverageCheckDelay(T, T + 10 * 60_000)).toBe(600_000)
    expect(nextCoverageCheckDelay(T, T + PENDING_SENT_MESSAGES_MAX_AGE_MS)).toBeNull()
  })
})

describe('coverPendingSentMessages', () => {
  test('does nothing without tracked messages', () => {
    expect(coverPendingSentMessages(archive(T), [], T)).toEqual({ archive: archive(T), changed: false })
  })

  test('moves the cutoff to a tracked message that went out past it and forgets it', () => {
    const result = coverPendingSentMessages(archive(T, ['a']), [state('a', { sentAt: T + 80 })], T)
    expect(result.bumpedTo).toBe(T + 80)
    expect(cutoff(result.archive)).toBe(T + 80)
    expect(result.archive.pendingSentMessageIDs).toBeUndefined()
  })

  test('keeps tracking a message that is still sending without using its provisional date', () => {
    const result = coverPendingSentMessages(archive(T, ['a', 'b']), [
      state('a', { sentAt: T + 5, isSent: false }),
      state('b', { sentAt: T + 9 }),
    ], T)
    expect(result.bumpedTo).toBe(T + 9)
    expect(result.archive.pendingSentMessageIDs).toEqual(['a'])
  })

  test('treats a failed message as settled', () => {
    const result = coverPendingSentMessages(archive(T, ['a']), [state('a', { sentAt: T + 3, isSent: false, isErrored: true })], T)
    expect(result.bumpedTo).toBe(T + 3)
    expect(result.archive.pendingSentMessageIDs).toBeUndefined()
  })

  test('leaves the cutoff alone when the tracked message is older than it', () => {
    const result = coverPendingSentMessages(archive(T, ['a']), [state('a', { sentAt: T - 100 })], T)
    expect(result.changed).toBe(true)
    expect(result.bumpedTo).toBeUndefined()
    expect(cutoff(result.archive)).toBe(T)
    expect(result.archive.pendingSentMessageIDs).toBeUndefined()
  })

  test('forgets a tracked message whose row is gone', () => {
    const result = coverPendingSentMessages(archive(T, ['gone', 'a']), [state('a', { isSent: false })], T)
    expect(result.archive.pendingSentMessageIDs).toEqual(['a'])
  })

  test('reports no change while every tracked message is still sending', () => {
    expect(coverPendingSentMessages(archive(T, ['a']), [state('a', { isSent: false })], T).changed).toBe(false)
  })

  test('stops tracking once the archive is older than the maximum age', () => {
    const result = coverPendingSentMessages(archive(T, ['a']), [state('a', { isSent: false })], T + PENDING_SENT_MESSAGES_MAX_AGE_MS)
    expect(result.archive.pendingSentMessageIDs).toBeUndefined()
    expect(cutoff(result.archive)).toBe(T)
  })

  test('ignores an archive whose cutoff cannot be read', () => {
    expect(coverPendingSentMessages({ archivedAt: '0' as ThreadArchivalState['archivedAt'], pendingSentMessageIDs: ['a'] }, [state('a')], T).changed).toBe(false)
  })
})
