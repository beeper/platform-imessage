import { ThreadArchivalState } from './persistence'
import { appleDateToMillisSinceEpoch, makeAppleDate } from './time'

export interface MessageSendState {
  id: string
  sentAt: number | null
  isSent: boolean
  isErrored: boolean
}

export const PENDING_SENT_MESSAGES_LIMIT = 20
export const PENDING_SENT_MESSAGES_MAX_AGE_MS = 7 * 24 * 60 * 60_000

export function normalizeSentAt(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

// How long to wait before looking at a tracked message again, by how long ago the chat was archived.
export function nextCoverageCheckDelay(archivedAt: number, now = Date.now()): number | null {
  const age = now - archivedAt
  if (age >= PENDING_SENT_MESSAGES_MAX_AGE_MS) return null
  if (age < 30_000) return 1_000
  if (age < 2 * 60_000) return 5_000
  if (age < 10 * 60_000) return 60_000
  return 10 * 60_000
}

export interface ArchiveCoverage {
  archive: ThreadArchivalState
  changed: boolean
  bumpedTo?: number
}

const unchanged = (archive: ThreadArchivalState): ArchiveCoverage => ({ archive, changed: false })

// Moves the cutoff forward to the final dates of tracked messages that have gone out, and forgets those.
export function coverPendingSentMessages(archive: ThreadArchivalState, states: MessageSendState[], now = Date.now()): ArchiveCoverage {
  const pending = archive.pendingSentMessageIDs ?? []
  if (!pending.length) return unchanged(archive)
  const archivedAt = appleDateToMillisSinceEpoch(archive.archivedAt)
  if (archivedAt == null) return unchanged(archive)
  if (now - archivedAt >= PENDING_SENT_MESSAGES_MAX_AGE_MS) return { archive: { archivedAt: archive.archivedAt }, changed: true }
  const byID = new Map(states.map(state => [state.id, state]))
  let cutoff = archivedAt
  const remaining: string[] = []
  for (const id of pending) {
    const state = byID.get(id)
    if (!state) continue
    if (!state.isSent && !state.isErrored) {
      remaining.push(id)
    } else if (state.sentAt != null) {
      cutoff = Math.max(cutoff, state.sentAt)
    }
  }
  const bumped = cutoff > archivedAt
  if (!bumped && remaining.length === pending.length) return unchanged(archive)
  return {
    archive: {
      archivedAt: bumped ? makeAppleDate(new Date(cutoff)) : archive.archivedAt,
      ...(remaining.length ? { pendingSentMessageIDs: remaining } : {}),
    },
    changed: true,
    bumpedTo: bumped ? cutoff : undefined,
  }
}
