---
id: beeper-desktop-architecture
title: Beeper Desktop Architecture
created: 2026-01-26
summary: How Beeper desktop communicates with bridges, stores thread data, and implements filtering
modified: 2026-01-26
---

# Beeper Desktop Architecture

TODO: Add content

## Overview

Beeper desktop is an Electron app that communicates with multiple messaging bridges (iMessage, Discord, etc.) through a Platform API Server (PAS) layer. Thread filtering happens entirely in-memory on the renderer side using MobX computed properties.

## Data Flow

```
Bridge (SwiftServer)
    ↓ NodeAPI / RPC
platform-imessage TypeScript (api.ts, mappers.ts)
    ↓ BeeperThread objects
PAS Server (pas-server/)
    ↓ RoomSyncContext → EventSyncContext
ThreadStore (renderer)
    ↓ MobX observables
WindowStateStore (filtering)
    ↓ computed filteredThreads
UI Components (ThreadsList, AccountFilters)
```

## Key Components

### 1. Bridge Layer (platform-imessage)

**Location:** `/Users/purav/Developer/Beeper/platform-imessage/src/`

- `api.ts` - Main `PlatformAPI` implementation
  - `getThreads()` - Fetches threads from chat.db
  - `getMessages()` - Fetches messages
  - `sendMessage()` - Sends via MessagesController (AX)
  
- `db-api.ts` - Direct SQLite queries to chat.db
  - `SQLS.getThreads` - SQL query for chat table
  - `SQLS.getMessages` - SQL query for messages
  
- `mappers.ts` - Converts DB rows to `BeeperThread`/`BeeperMessage`
  - `mapThread()` - Single thread mapping
  - `mapThreads()` - Batch mapping
  - `mapMessages()` - Message mapping

### 2. PAS Server Layer

**Location:** `/Users/purav/Developer/Beeper/beeper/desktop/src/pas-server/`

- `types.ts` - `PlatformAPIRelayerData` RPC format
- `beeper/RoomSyncContext.ts` - Thread synchronization
- `beeper/EventSyncContext.ts` - Event processing pipeline
- `beeper/BeeperClient.ts` - Main client interfacing with bridges

### 3. Renderer Stores (MobX)

**Location:** `/Users/purav/Developer/Beeper/beeper/desktop/src/renderer/stores/`

- `ThreadStore.ts` - Individual thread state
  - `@observable unreadCount`
  - `@observable isMarkedUnread`
  - `@computed isUnread` - `isMarkedUnread || unreadCount > 0`
  - `@computed filterBucket` - From `extra.filterBucket`
  
- `WindowStateStore.ts` - Window-level state
  - `@observable threadsFolder` - Current folder (Inbox, Archive, etc.)
  - `@observable threadsFilter` - Current filter (Unread, Drafts, etc.)
  - `filterThreads()` - Applies folder + filter logic
  - `@computed filteredThreads` - Final filtered list for UI

- `AccountStore.ts` - Per-account state
- `RootStore.ts` - Global state container

### 4. UI Components

**Location:** `/Users/purav/Developer/Beeper/beeper/desktop/src/renderer/components/`

- `AccountFilters/AccountFilters.tsx`
  - `VISIBLE_THREAD_FILTERS` - Which filters show in dropdown
  - `THREAD_FILTER_NAMES` - Display names for filters
  - `FilterButton` - Clickable filter button with chevron
  
- `ThreadsList.tsx` - Virtual scrolling thread list
- `Thread.tsx` - Individual thread item

## Filtering System

### Enums (`src/common/enums.ts`)

```typescript
// Folder = which inbox section
enum ThreadsFolder {
    DEFAULT = 'default',      // Main inbox
    ARCHIVED = 'archived',    // Archived chats
    LOW_PRIORITY = 'low_priority',
    REQUESTS = 'requests',    // Message requests
}

// Filter = within a folder, which subset
enum ThreadsFilter {
    DEFAULT = 'default',      // No filter (show all)
    UNREAD = 'unread',
    DRAFTS = 'drafts',
    UNRESPONDED = 'unresponded',
    GROUP = 'group',
    MUTED = 'muted',
    UNKNOWN = 'unknown',
    HIDDEN = 'hidden',
    // iMessage SMS buckets (added)
    TRANSACTIONS = 'transactions',
    PROMOTIONS = 'promotions',
    SPAM = 'spam',
    UNKNOWN_SENDERS = 'unknown_senders',
}
```

### Filter Logic (`WindowStateStore.ts:614`)

```typescript
switch (threadsFilter) {
    case ThreadsFilter.GROUP: return t.hasMultipleParticipants
    case ThreadsFilter.UNREAD: return t.isUnread || this.selectedThread === t
    case ThreadsFilter.UNRESPONDED: return t.isUnresponded
    case ThreadsFilter.MUTED: return t.isMuted
    case ThreadsFilter.DRAFTS: return t.hasDraft
    // ... etc
}
```

The filter dropdown shows count for each filter via `wss.threadsCount(folder, filter)`.

## Thread Properties (BeeperThread)

Key fields passed from bridge → desktop:

```typescript
interface BeeperThread {
    id: string
    title?: string
    type: 'group' | 'single'
    timestamp: Date
    unreadCount?: number
    isMarkedUnread: boolean
    participants: Paginated<Participant>
    messages: Paginated<BeeperMessage>
    extra?: BeeperThreadExtra  // Contains filterBucket, isSMS, etc.
}

interface BeeperThreadExtra {
    filterBucket?: 'unknownSenders' | 'transactions' | 'promotions' | 'spam'
    isSMS?: true
    tags?: { [tag: string]: any }
    isArchivedUpToOrder?: number
    // ... etc
}
```

## Adding New Filters

To add a new filter type:

1. Add enum value to `ThreadsFilter` in `enums.ts`
2. Add computed property to `ThreadStore.ts` (e.g., `@computed get isTransaction()`)
3. Add switch case in `WindowStateStore.ts` `filterThreads()`
4. Add to `VISIBLE_THREAD_FILTERS` array in `AccountFilters.tsx`
5. Add display name to `THREAD_FILTER_NAMES` record

## References

See {@chatdb-message-filtering} for the iMessage-specific filtering implementation.
