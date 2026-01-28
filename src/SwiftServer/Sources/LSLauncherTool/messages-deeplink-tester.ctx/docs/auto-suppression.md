---
id: auto-suppression
title: Auto-Suppression
created: 2026-01-27
summary: How LSTypeObserver auto-suppresses Messages to UIElement mode - Updated with Hopper analysis findings
modified: 2026-01-27
---

# Auto-Suppression

TODO: Add content

## How It Works

1. `LSTypeObserver` subscribes to LaunchServices notifications (code 0x231 = applicationTypeChanged)
2. When Messages tries to become Foreground, the observer detects the type change
3. Auto-suppress immediately sets the app back to UIElement mode
4. This prevents the Dock icon from appearing (or minimizes visibility time)

## Application Modes

| Mode | Dock Icon | UI Allowed |
|------|-----------|------------|
| Foreground | Yes | Yes |
| UIElement | No | Yes |
| BackgroundOnly | No | No |

## Key APIs (Private LaunchServices)

```swift
// Set application type
_LSSetApplicationInformationItem(sessionID, asn, kLSApplicationTypeKey, "UIElement")

// Also set restore type to prevent self-promotion
_LSSetApplicationInformationItem(sessionID, asn, kLSApplicationTypeToRestoreKey, "UIElement")
```

## Known Issue

The type observer handler has a bug (noted in code):
```
// FIXME: (@pmanot) - Handler is currently broken, sometimes does not return the right type or pid
```

However, auto-suppress still works because it checks ALL tracked apps on any type change notification.

## Log Format

Type changes are logged to `type_changes.json`:
```json
{
  "timestamp": "2026-01-27T12:30:05Z",
  "pid": 12345,
  "bundleID": "com.apple.MobileSMS",
  "oldType": "UIElement",
  "newType": "Foreground",
  "suppressionLatencyMs": 45.2,
  "deepLinkURL": "imessage://open?message-guid=..."
}
```

## Hopper Analysis (2026-01-27)

### Notification Callback Signature

From decompilation of `LSNotificationReceiver::CreateNotification`:

```swift
typealias LSNotificationBlock = @convention(block) (
    LSNotificationCode,    // code (0x231 for applicationTypeChanged)
    Double,                // timestamp
    UnsafeRawPointer?,     // info (CFDictionary)
    UnsafeRawPointer?,     // asnPtr (LSASN)
    LSSessionID,           // sessionID
    UnsafeRawPointer?      // context
) -> Void
```

### The `info` Parameter

The `info` pointer is a `CFDictionary` parsed from XPC:
```c
r23 = _MyCFXPCCreateCFObjectFromXPCObject(xpc_dictionary_get_value(var_D8, "info"), 0x0);
```

The callback invocation at `0x180a81d84` passes:
- code, timestamp (double), info dictionary, ASN, sessionID, context

### Previous Bug

The original code ignored the `info` parameter entirely, only using the ASN to look up the app and query its current type. This caused issues because:
1. The old type was tracked in an internal `lastKnownTypes` cache (not reliable for first notifications)
2. There's a race condition between notification and type query
3. The actual type change data in `info` was being discarded

### Fix Applied

Updated `handleNotification` to:
1. Parse the `info` CFDictionary
2. Extract old/new types from common key names
3. Fall back to ASN-based lookup if info dict doesn't have the data
4. Added DEBUG logging to identify actual key names used by LaunchServices

### Key Names Found in LaunchServices

From string search in Hopper:
- `kLSApplicationTypeKey` - current application type
- `kLSApplicationTypeToRestoreKey` - type to restore after minimize
- Type values: "Foreground", "UIElement", "BackgroundOnly"

### Type Flags from Shared Memory

From `_LSAppInfoGetApplicationTypeFuncPK` at `0x180c6dd88`:
- Flag 0x10 = BackgroundOnly
- Flag 0x20 = UIElement  
- Default = Foreground
