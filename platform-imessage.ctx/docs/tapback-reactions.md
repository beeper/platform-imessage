---
id: tapback-reactions
title: Tapback Reactions Implementation
created: 2026-01-24
summary: Analysis of tapback reaction approaches: SwiftServer vs direct AX actions
modified: 2026-01-24
---

# Tapback Reactions Implementation

TODO: Add content

## Overview

Two approaches exist for applying tapback reactions in Messages.app:

1. **SwiftServer (current)**: UI automation - opens reaction picker, presses buttons
2. **Direct AX Actions (new)**: Invoke custom accessibility actions directly on message elements

## Key Discovery

Message elements (identifier: `Sticker`) in the TranscriptCollectionView have **custom accessibility actions** for tapback reactions that can be invoked directly, bypassing the reaction picker UI entirely.

### Available Custom Actions on Message Elements

**Standard Tapbacks:**
- `Heart`
- `Thumbs up`
- `Thumbs down`
- `Ha ha!`
- `Exclamation mark`
- `Question mark`

**Custom Emoji (Sequoia+):**
- Limited set of pre-populated emojis (❤️, 🔥, 🤗, 🤣, 🫂, etc.)
- NOT arbitrary - only emojis that macOS makes available as direct actions

**Other Actions:**
- `Add Emoji as Tapback` - opens character picker for arbitrary emoji
- `Copy`, `Delete…`, `Forward…`, `Reply…`, etc.

## Hybrid Approach (Recommended)

Combine deep link navigation with direct action invocation:

### Flow
1. Open deep link: `imessage://open?message-guid=<GUID>&overlay=1`
2. With `overlay=1`, only ONE Sticker element is visible (the target message)
3. Find the Sticker element in TranscriptCollectionView
4. Invoke custom action directly: e.g., `Heart`, `Thumbs up`

### Advantages over Current SwiftServer
| Current Approach | Hybrid Approach |
|-----------------|-----------------|
| Opens reaction picker UI | Direct action invocation |
| Waits for animations (0.75s+) | No animation wait |
| Finds buttons by index/identifier | Single action call |
| Different code paths for Sequoia/older | Same code path |
| Custom emoji: character picker navigation | Limited to available emoji actions |

### Verified Working
Tested with axdump and confirmed reactions appear in chat.db:
- `2000` = reacted_heart
- `2001` = reacted_like  
- `3000` = unreacted_heart (toggle off)
- `3001` = unreacted_like (toggle off)

## Message Discovery

### SwiftServer Approach
- Uses `MessageCell` struct with: messageGUID, offset, cellID, cellRole
- Opens deep link `imessage://open?message-guid=<GUID>` to navigate
- Messages.app selects the message
- `firstSelectedMessageCell()` finds element where `isSelected() == true`
- Validates using cellID and cellRole

### With overlay=1
- Deep link opens reply overlay showing only the target message
- Only ONE Sticker element visible - no need to find selected
- Much simpler element discovery

### Without overlay
- Multiple messages visible
- Need to find selected element (but `isSelected` may be transient)
- SwiftServer handles this with retry logic

## Arbitrary Emoji Limitation

**Direct actions only support a limited set of custom emojis.**

For arbitrary emoji (any Unicode character), must use:
1. Invoke `Add Emoji as Tapback` action (opens character picker)
2. Search in the popover search field
3. Navigate results with arrow keys (6-column grid)
4. Press return to select

This is what SwiftServer does for `.custom(emoji:)` reactions - no clean alternative exists.

## Key Files

- `SwiftServer/Sources/SwiftServer/Reaction.swift` - Reaction enum
- `SwiftServer/Sources/SwiftServer/MessagesController.swift` - setReaction() at line ~800
- `SwiftServer/Sources/SwiftServer/MessagesAppElements.swift` - AX element helpers
- `SwiftServer/Sources/SwiftServer/MessagesDeepLink.swift` - Deep link URL construction

## Testing Tool

`/Users/purav/Developer/Beeper/BeeperTesting/BeeperTesting/TapbackTestView.swift` - SwiftUI test harness for tapback reactions using direct AX actions.

## axdump Tool

`/Users/purav/Developer/Beeper/BetterSwiftAX` - CLI tool for AX exploration.

Example commands:
```bash
# Find Messages PID
axdump list | grep Messages

# Find all Sticker elements
axdump find <pid> --id Sticker --all -v

# List actions on a message
axdump action <pid> --list -p <path>

# Invoke custom action
axdump action <pid> -C "Heart" -p <path>
```

## References

- {@reaction-constants} - chat.db constants and action name mappings
