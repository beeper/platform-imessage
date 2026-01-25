---
id: ax-chatdb-mapping
title: Mapping AX Elements to chat.db Messages
created: 2026-01-24
summary: Research into connecting macOS Accessibility elements in Messages.app to their corresponding records in chat.db
modified: 2026-01-25
---

# Mapping AX Elements to chat.db Messages

TODO: Add content

## Problem Statement

When automating iMessage via Accessibility APIs, there's no reliable way to map AX elements (message rows in the UI) to their corresponding records in chat.db. This is needed for operations like setting reactions on specific messages.

### Challenges
- Multiple messages can be grouped visually
- Links/rich content create extra AX rows not in chat.db
- AX identifiers are runtime-only, not persistent
- No GUID exposed through standard AX attributes

## Current Approach

The platform-imessage codebase uses deep links + offset arithmetic:
1. Query chat.db for message GUID
2. Open `imessage://open?message-guid=<GUID>`
3. Find selected AX element
4. Use frame-based offset to navigate to target message part

This is fragile because visual grouping doesn't match database structure.

## Technical Findings

### AXUIElement Internal Structure (HIServices.framework)

Analyzed via Hopper disassembly of `__AXUIElementCreateInternal`:

```
Offset 0x10: PID (Int32)
Offset 0x14: Flags (UInt32) 
Offset 0x20: Internal CFData pointer
Offset 0x30: Element ID (UInt64) - runtime only, changes between sessions
```

The internal CFData (36 bytes) contains:
```
0x00-0x0F: Fixed marker (0x7ffffffffffffffe twice)
0x10-0x13: PID
0x14-0x17: Some identifier
0x18-0x1B: Type/flag (always 0x0a)
0x1C-0x1F: Element index - VARIES per element but NOT the GUID
0x20-0x23: Zero padding
```

**Conclusion**: AXUIElement internal data does NOT contain message GUIDs.

### AX Attributes on Message Cells

Using axdump tool, inspected `#Sticker` elements (message bubbles):

| Attribute | Value |
|-----------|-------|
| AXRole | AXGroup |
| AXIdentifier | "Sticker" (static, not message-specific) |
| AXDescription | "{Sender}, {MessageText}, {Time}" |
| AXCustomContent | Empty NSMutableArray (bplist) |
| AXUserInputLabels | Message text only |

**No GUID or message-specific identifier exposed.**

### ChatKit.framework Structure

The UI layer that renders messages:

```
CKTranscriptBalloonCell
  └── configureForChatItem:context:animated:... 
       └── receives CKChatItem
            └── .IMChatItem property
                 └── .guid property  ← THE DATABASE GUID!
```

Key methods found:
- `-[CKTranscriptCollectionViewController chatItemForGUID:]` - looks up CKChatItem by GUID
- `-[CKAttachmentCollectionManager guidFromChatItem:]` - extracts GUID from chat item
- `-[CKAssociatedStickerTranscriptCell chatItemGUID]` - cells store GUID in ivar

**The cells know their GUIDs but don't expose them via Accessibility.**

## Potential Solutions

### 1. Accessibility Bundle Injection (No SIP Required - Needs Verification)

macOS can load `.axbundle` files into apps for assistive technology:

```
MyAXBundle.axbundle/
├── Contents/
│   ├── Info.plist (NSAccessibilityServiceType: AXUIElementService)
│   └── MacOS/MyAXBundle
```

Principal class swizzles `configureForChatItem:` to capture cell→GUID mapping.

**Caveat**: Uncertain if this still works on modern macOS (Sequoia) with hardened runtime.

### 2. Frida Runtime Hooking (Requires SIP Disabled)

Hook `CKTranscriptBalloonCell` methods to intercept GUID assignment:

```javascript
Interceptor.attach(
  ObjC.classes.CKTranscriptBalloonCell['- configureForChatItem:context:...'].implementation,
  {
    onEnter: function(args) {
      var chatItem = ObjC.Object(args[2]);
      var guid = chatItem.IMChatItem().guid().toString();
      // Map to cell identity
    }
  }
);
```

Requires: `csrutil enable --without debug` at minimum.

### 3. Position-Based Heuristic Matching (No Privileges)

Match AX elements to chat.db by combining:
- Message text from AXDescription
- Timestamp window
- **Relative position in transcript** (AX tree order ≈ visual order ≈ ROWID order)

```swift
let cells = getMessageCells(transcriptView)  // ordered by frame.y
let dbMessages = db.messages(in: chatGUID, orderedBy: .rowid)
// Match by position within same-minute windows
```

### 4. Deep Link + AXObserver Caching (Current Approach Enhanced)

Register AXObserver before opening deep links, cache mappings:
- Watch for `kAXSelectedChildrenChangedNotification`
- Open `imessage://open?message-guid=<GUID>`
- Capture selected element → build persistent mapping

## Recommendation

**Most promising path**: Accessibility Bundle injection if it works on modern macOS, otherwise position-based heuristic matching as a fallback.

The axbundle approach is the "blessed" mechanism Apple provides for assistive technology and doesn't require SIP changes. Worth prototyping to verify it still works with hardened runtime apps.

## Open Questions

1. Do axbundles still load into hardened runtime apps on macOS Sequoia?
2. Can we use distributed notifications to communicate from inside Messages.app?
3. Is there an XPC service we could observe for message→UI mapping?

## Related Files

- {@hopper-hiservices} - HIServices disassembly notes
- {@hopper-chatkit} - ChatKit disassembly notes  
- {@axdump-output} - Sample AX tree dumps

## Index Correlation Approach (New Findings)

From deeper Hopper analysis of ChatKit (Untitled 2 in Hopper), the index-based correlation approach is promising:

### Key Insight: AX Tree Order ≈ Visual Order ≈ Database Order

The CKTranscriptCollectionViewController uses NSIndexPath to identify cells:
- `chatItemAtIndexPath:` (0x1d5556504) - returns CKChatItem for index
- `indexPathForChatItemGUID:` (0x1d556fe3c) - maps GUID → index
- `indexPathForMessageGUID:messagePartIndex:` (0x1d6066619) - maps message GUID + part index → index

The cells are ordered by their Y position in the scroll view, which corresponds to:
1. Visual top-to-bottom order in UI
2. Date/ROWID order in chat.db (oldest at top, newest at bottom)

### Index Correlation Strategy

```
AXUIElement Tree          chat.db
-----------------         --------
[0] Message Cell    ←→    ROWID N   (oldest visible)
[1] Message Cell    ←→    ROWID N+1
[2] Message Cell    ←→    ROWID N+2
...                       ...
[K] Message Cell    ←→    ROWID N+K (newest visible)
```

The AX tree children are ordered by frame.minY (top to bottom), matching the visual order.

### Caveats

1. **Grouped messages**: Multiple parts of same message may appear as separate AX elements
2. **Rich links**: May create extra rows not in chat.db message table
3. **Reactions/Tapbacks**: Appear as associated items with different indexing
4. **Scroll position**: Only visible cells are in AX tree

### Test Script

Created `ax-index-explorer.swift` in this ctx folder. Run with:
```bash
swift ax-index-explorer.swift [hierarchy|cells|text|all]
```

Modes:
- `hierarchy` - Show full AX tree structure
- `cells` - Find AXCell elements with their indexes
- `text` - Find all text sorted by Y position
- `all` - Run all modes
