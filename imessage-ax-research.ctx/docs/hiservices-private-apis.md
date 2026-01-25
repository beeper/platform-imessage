---
id: hiservices-private-apis
title: HIServices Private Accessibility APIs
created: 2026-01-25
summary: Private APIs in HIServices for efficient AX tree querying, element identification, and enhanced notifications
modified: 2026-01-25
---

# HIServices Private Accessibility APIs

TODO: Add content

## Overview

Analysis of HIServices framework binary reveals several private APIs useful for:
1. **Efficient AX tree querying** - batch operations, hierarchy copying
2. **Element identification** - hash-based IDs, remote tokens
3. **Enhanced observers** - info callbacks with additional context
4. **Hit testing** - including ignored elements

## 1. Efficient Tree Querying

### AXUIElementCopyHierarchy
```c
AXError AXUIElementCopyHierarchy(
    AXUIElementRef element,
    CFArrayRef attributeNames,  // attributes to fetch for each element
    CFDictionaryRef options,    // optional filter/config
    CFArrayRef *hierarchy       // out: flattened hierarchy with attributes
);
```
Copies entire AX subtree in a single IPC call. Much more efficient than recursive `AXUIElementCopyAttributeValue` calls.

### AXUIElementCopyMultipleAttributeValues  
```c
AXError AXUIElementCopyMultipleAttributeValues(
    AXUIElementRef element,
    CFArrayRef attributeNames,
    AXCopyMultipleAttributeOptions options,  // e.g., kAXCopyMultipleAttributeOptionStopOnError
    CFArrayRef *values
);
```
Batch fetch multiple attributes in one call. Already semi-public but underutilized.

### Private Attributes for Navigation
- `AXChildrenInNavigationOrder` - children ordered for keyboard navigation
- `AXChildrenOrdered` - children in display order
- `AXChildrenHash` - hash of children for change detection
- `AXChildrenHashWithRelativeFrameAttribute` - includes position in hash
- `AXRelativeFrame` - frame relative to parent (not screen coords)

## 2. Element Identification

### Remote Token APIs
```c
// Create a serializable token from an element
CFDataRef _AXUIElementRemoteTokenCreate(AXUIElementRef element);

// Recreate element from token
AXUIElementRef _AXUIElementCreateWithRemoteToken(CFDataRef token);
```

Token structure (12+ bytes):
- bytes 0-3: pid (int32)
- bytes 4-7: element data (int32) 
- bytes 8-11: window ID (int32)
- bytes 12+: optional CFData payload

### AXUIElement Internal Structure
From `_AXUIElementCreateInternal`:
```c
struct AXUIElement {
    CFRuntimeBase _base;
    pid_t pid;           // offset 0x10
    int32_t windowID;    // offset 0x14  
    int32_t elementData; // offset 0x18
    CFDataRef data;      // offset 0x20 - optional element-specific data
    void* reserved;      // offset 0x28
};
```

### _AXUIElementGetData
```c
AXError _AXUIElementGetData(
    AXUIElementRef element,
    CFDataRef *outData,     // internal element data
    int32_t *outElementID   // internal element identifier
);
```

### Children Hash for Change Detection
```c
CFNumberRef _AXCopyChildrenHash(AXUIElementRef element);
CFNumberRef _AXCopyChildrenHashWithRelativeFrame(AXUIElementRef element);
```
Hash computed from: element hash + frame + parent + children frames.
Useful for detecting subtree changes without full traversal.

## 3. Enhanced Observers

### AXObserverCreateWithInfoCallback
```c
AXError AXObserverCreateWithInfoCallback(
    pid_t application,
    AXObserverCallbackWithInfo callback,
    AXObserverRef *outObserver
);

typedef void (*AXObserverCallbackWithInfo)(
    AXObserverRef observer,
    AXUIElementRef element,
    CFStringRef notification,
    CFDictionaryRef info,  // Additional notification context!
    void *refcon
);
```
The info dictionary can contain:
- Changed values
- Old/new state
- Affected ranges (for text changes)
- Element-specific metadata

### _AXUIElementPostNotificationWithInfo
```c
AXError _AXUIElementPostNotificationWithInfo(
    AXNotificationHandler handler,
    CFStringRef notification,
    AXUIElementRef element,
    CFDictionaryRef info  // up to 1024 chars notification name
);
```
Server-side API to post notifications with additional context.

### _AXNotificationHandlerCreateWithCallback
Internal notification handler creation with custom callbacks.

## 4. Hit Testing & Ignored Elements

### _AXUIElementCopyElementAtPositionIncludeIgnored
```c
AXError _AXUIElementCopyElementAtPositionIncludeIgnored(
    AXUIElementRef application,
    AXUIElementRef *outElement,
    CGPoint position  // d8=x, d9=y in float regs
);
```
Unlike public `AXUIElementCopyElementAtPosition`, this returns elements that would normally be filtered out (decorative elements, containers marked as ignored).

### Related Attributes
- `AXHitTestIgnoredElementAtPosition` - attribute for hit testing
- `AXShouldElementBeIgnoredForNavigation` - check if element is ignored

## 5. Window & Process APIs

### _AXUIElementGetWindow
```c
AXError _AXUIElementGetWindow(
    AXUIElementRef element,
    CGWindowID *outWindowID
);
```
Get the CGWindowID for an element - useful for correlating with CGWindowList APIs.

### _AXUIElementCreateApplicationWithPresenterPid
```c
AXUIElementRef _AXUIElementCreateApplicationWithPresenterPid(
    pid_t targetPid,
    pid_t presenterPid  // for remote/presented content
);
```

### _AXUIElementGetIsProcessSuspended
Check if target process is suspended (affects AX availability).

## 6. Bundle & Extension Management

### _AXUIElementLoadAccessibilityBundles
```c
void _AXUIElementLoadAccessibilityBundles(void);
```
Loads accessibility bundles that can extend AX functionality.

### AXBBundleManager Functions
- `AXBBundleManagerLoadAXBundlesWithClientToken` - load bundles with auth token
- `AXBBundleManagerLoadRequiredAXBundlesWithClientToken` - load required bundles

## 7. Private Attributes Discovered

| Attribute | Description |
|-----------|-------------|
| `AXChildrenHash` | Hash of children for change detection |
| `AXChildrenHashWithRelativeFrameAttribute` | Hash including frame positions |
| `AXChildrenInNavigationOrder` | Keyboard nav order |
| `AXChildrenOrdered` | Display order |
| `AXRelativeFrame` | Frame relative to parent |
| `AXEnhancedUserInterface` | Enhanced UI mode flag |
| `AXAutomationType` | Type of automation access |
| `AXElementToFocusForLayoutChange` | Suggested focus target |
| `AXShowDefaultUI` / `AXShowAlternateUI` | UI mode switches |

## 8. Serialization Format

Elements serialize to:
```
[0x0a type marker][4 bytes CFData ptr][8 bytes frame as 2 floats][4 bytes length][N bytes data]
```

The `_AXUIElementRemoteTokenCreate` creates a portable 12+ byte token containing pid, windowID, and element data that can recreate the element across processes.

## 9. Threading & Performance

### _AXUIElementSetGlobalTimeout
```c
void _AXUIElementSetGlobalTimeout(int milliseconds);
```
Default is 1500ms (0x5dc). Set global timeout for all AX operations.

### _AXUIElementUseSecondaryAXThread
```c
AXError _AXUIElementUseSecondaryAXThread(bool enable);
```
Spawn a secondary thread for AX operations to avoid blocking main thread.
Requires prior call to `_AXUIElementRegisterServerWithRunLoop`.

### _AXUIElementRequestServicedBySecondaryAXThread
Request that current AX operation be serviced by secondary thread.

## 10. Server-Side Registration (for implementing AX servers)

### _AXUIElementRegisterServerWithRunLoop
```c
AXError _AXUIElementRegisterServerWithRunLoop(
    AXServerCallbacks *callbacks,  // struct with ~19 callback pointers
    void *userData,
    CFRunLoopRef runLoop           // NULL = main runloop
);
```

Registers your process as an AX server. The callbacks struct contains handlers for:
- GetAttributeNames, CopyAttributeValue, SetAttributeValue
- GetActionNames, CopyActionDescription, PerformAction
- GetParameterizedAttributeNames, CopyParameterizedAttributeValue
- IsAttributeSettable, GetAttributeValueCount
- CopyAttributeValues, CopyMultipleAttributeValues
- CopyElementAtPosition, CopyHierarchy
- GetWindow, and more...

Uses MIG subsystem `_AXXMIGAccessibilityClientDefs_subsystem` for IPC.
Listens on `kAXServerRunLoopMode` and `kCFRunLoopCommonModes`.

## 11. Text Markers (for text identification)

### AXTextMarkerCreate
```c
AXTextMarkerRef AXTextMarkerCreate(
    CFAllocatorRef allocator,
    const UInt8 *bytes,      // opaque marker data
    CFIndex length           // byte length
);
```
Creates a text marker from raw bytes. Text markers are opaque identifiers for positions in text.

### AXTextMarkerRangeCreate
```c
AXTextMarkerRangeRef AXTextMarkerRangeCreate(
    CFAllocatorRef allocator,
    AXTextMarkerRef startMarker,
    AXTextMarkerRef endMarker
);
```

### Related Functions
- `AXTextMarkerGetBytePtr` - get raw bytes from marker
- `AXTextMarkerGetLength` - get byte length
- `AXTextMarkerRangeCopyStartMarker` / `CopyEndMarker`
- `AXTextMarkerRangeCreateWithBytes` - create range directly from bytes

Text markers are stable identifiers for text positions even as content changes.

## 12. Navigation Ordering

### _AXCreateElementOrdering
Creates sorted ordering of elements for navigation purposes.

### _AXShouldElementBeIgnoredForNavigation
```c
bool _AXShouldElementBeIgnoredForNavigation(AXUIElementRef element);
```
Check if element should be skipped in keyboard navigation.

### _AXCopyAttributeValueForChildrenNavigation
Get children sorted for navigation order.

### Navigation Order Attributes
- `AXElementOrderHorizontalKey` - horizontal sort key
- `AXElementOrderVerticalKey` - vertical sort key

## 13. Element Identity & Hashing

### How Elements Are Identified
From `___AXUIElementHash` and `___AXUIElementEqual`, element identity is based on:

```c
// Hash = pid + elementData + CFHash(data)
hash = element->pid + element->elementData + CFHash(element->data);

// Equality checks:
// 1. element->elementData must match (offset 0x18 - window/element ID)
// 2. element->pid must match (offset 0x10)  
// 3. element->data must CFEqual (offset 0x20 - additional opaque data)
```

### Stable Element Identification Strategy
1. **Remote Token**: Use `_AXUIElementRemoteTokenCreate()` to get a portable token
2. **Children Hash**: Use `AXChildrenHash` attribute for subtree fingerprinting
3. **Combined Key**: pid + windowID + elementData forms unique identity

### Element Structure Offsets
| Offset | Field | Description |
|--------|-------|-------------|
| 0x10 | pid | Process ID |
| 0x14 | presenterPid | Presenter PID (for remote) |
| 0x18 | elementData | Element-specific identifier |
| 0x20 | data | CFDataRef with additional info |
| 0x28 | timeout | Per-element timeout (0 = global) |

## 14. Summary: Most Useful Private APIs

### For Efficient Tree Querying
| API | Purpose |
|-----|---------|
| `AXUIElementCopyHierarchy` | Batch fetch entire subtree with attributes |
| `AXUIElementCopyMultipleAttributeValues` | Fetch multiple attributes in one call |
| `AXChildrenInNavigationOrder` | Get children in keyboard nav order |
| `AXChildrenOrdered` | Get children in display order |

### For Element Identification
| API | Purpose |
|-----|---------|
| `_AXUIElementRemoteTokenCreate` | Create portable 12+ byte token |
| `_AXUIElementCreateWithRemoteToken` | Recreate element from token |
| `_AXUIElementGetData` | Get internal element data and ID |
| `AXChildrenHash` | Hash for subtree change detection |

### For Enhanced Observers
| API | Purpose |
|-----|---------|
| `AXObserverCreateWithInfoCallback` | Observer with info dictionary |
| `_AXUIElementPostNotificationWithInfo` | Post notification with context |

### For Performance
| API | Purpose |
|-----|---------|
| `_AXUIElementSetGlobalTimeout` | Adjust timeout (default 1500ms) |
| `_AXUIElementUseSecondaryAXThread` | Offload to secondary thread |
| `_AXUIElementCopyElementAtPositionIncludeIgnored` | Hit test including hidden elements |

## 15. Usage Notes

### Calling Private APIs from Swift
```swift
// Link against ApplicationServices framework
// Use dlsym to get function pointers

typealias AXUIElementCopyHierarchyFunc = @convention(c) (
    AXUIElement, CFArray, CFDictionary?, UnsafeMutablePointer<CFArray?>
) -> AXError

let handle = dlopen(nil, RTLD_NOW)
let sym = dlsym(handle, "AXUIElementCopyHierarchy")
let fn = unsafeBitCast(sym, to: AXUIElementCopyHierarchyFunc.self)
```

### Stability Considerations
- These are private APIs and may change between macOS versions
- Test thoroughly on target macOS versions
- Have fallbacks to public APIs where possible
- The element internal structure and token format may vary
