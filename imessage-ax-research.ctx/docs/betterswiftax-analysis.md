---
id: betterswiftax-analysis
title: BetterSwiftAX Analysis & Private API Opportunities
created: 2026-01-25
summary: Analysis of existing BetterSwiftAX code and opportunities to use private HIServices APIs
modified: 2026-01-25
---

# BetterSwiftAX Analysis & Private API Opportunities

TODO: Add content

## Current State

### BetterSwiftAX (base library)
Located at `/Users/purav/Developer/Beeper/BetterSwiftAX`

**Already has:**
- `_AXUIElementGetWindow` - declared in `CAccessibilityControl/include/AXPrivate.h`
- `AXObserverCreateWithInfoCallback` - used in Observer.swift (already using the info callback!)
- Basic element operations via public APIs

**Key files:**
- `Element.swift` - Core element wrapper, uses public APIs for attribute/action access
- `Observer.swift` - Already uses `AXObserverCreateWithInfoCallback` for info dictionary in notifications
- `Attribute.swift` - Attribute fetching one at a time via `AXUIElementCopyAttributeValue`
- `AXPrivate.h` - Private API declarations (currently only has `_AXUIElementGetWindow`)

### BetterSwiftAXAdditions (platform-imessage extensions)
Located at `/Users/purav/Developer/Beeper/platform-imessage/src/SwiftServer/Sources/BetterSwiftAXAdditions`

**Key functionality:**
- `recursiveChildren()` - BFS tree traversal with complexity limit (3600 elements)
- `recursivelyFindChild(withID:)` - Linear search through all children
- `XMLDumper` - Full tree dump for debugging
- Various attribute/action name definitions

## Private API Opportunities

### 1. Replace `recursiveChildren()` with `AXUIElementCopyHierarchy`

**Current code** (`AccessibilityElement+Additions.swift:26-47`):
```swift
func recursiveChildren(maxTraversalComplexity: Int = 3_600) -> AnySequence<Accessibility.Element> {
    var traversalComplexity = 0
    return AnySequence(sequence(state: [self] as Deque) { queue -> Accessibility.Element? in
        guard traversalComplexity < maxTraversalComplexity else { return nil }
        guard let elt = queue.popFirst() else { return nil }
        if let children = try? elt.children() {
            defer { traversalComplexity += 1 }
            queue.append(contentsOf: children)  // ONE IPC CALL PER ELEMENT!
        }
        return elt
    })
}
```

**Problem:** Makes one IPC call per element (N calls for N elements)

**Solution:** Use `AXUIElementCopyHierarchy` to fetch entire subtree in ONE call:
```swift
func copyHierarchy(attributes: [String]) throws -> [Accessibility.Element] {
    var result: CFArray?
    try check(AXUIElementCopyHierarchy(raw, attributes as CFArray, nil, &result))
    return (result as? [AXUIElement])?.map { Element(raw: $0) } ?? []
}
```

**Benefit:** O(1) IPC calls instead of O(N)

### 2. Replace individual attribute fetches with `AXUIElementCopyMultipleAttributeValues`

**Current code** (`Attribute.swift:26-34`):
```swift
public func callAsFunction() throws -> Value {
    var val: AnyObject?
    try Accessibility.check(
        AXUIElementCopyAttributeValue(element.raw, name.value as CFString, &val)  // ONE CALL PER ATTRIBUTE
    )
    return try val.flatMap(Accessibility.convertFromAX).orThrow(...)
}
```

**Usage in XMLDumper** (`Element+Dump.swift:87-94`):
```swift
if let supportedAttributes = try? element.supportedAttributes() {
    let attributes = Dictionary(
        supportedAttributes
            .filter { !excludedAttributes.contains($0.name.value) }
            .map { attribute in (attribute.name.value, try? attribute()) }  // N CALLS!
    )
}
```

**Solution:** Batch fetch attributes:
```swift
func copyMultipleAttributes(_ names: [String], options: AXCopyMultipleAttributeOptions = []) throws -> [Any?] {
    var values: CFArray?
    try check(AXUIElementCopyMultipleAttributeValues(raw, names as CFArray, options, &values))
    return values as? [Any?] ?? []
}
```

**Benefit:** Fetch 20 attributes in 1 IPC call instead of 20 calls

### 3. Add Element Identification via Remote Tokens

**Current limitation:** No way to persistently identify elements across sessions

**New capability:**
```swift
extension Accessibility.Element {
    /// Create a portable token that can identify this element
    func createRemoteToken() -> Data? {
        guard let cfData = _AXUIElementRemoteTokenCreate(raw) else { return nil }
        return cfData as Data
    }
    
    /// Recreate element from a previously created token
    convenience init?(remoteToken: Data) {
        guard let element = _AXUIElementCreateWithRemoteToken(remoteToken as CFData) else {
            return nil
        }
        self.init(raw: element)
    }
}
```

**Use cases:**
- Store element references that survive app restarts
- Compare elements across time (did we see this element before?)
- Cache element lookups

### 4. Add Children Hash for Change Detection

**Current limitation:** To detect changes, must re-traverse and compare

**New capability:**
```swift
extension Accessibility.Element {
    /// Get a hash of the element's children (changes when subtree changes)
    func childrenHash() throws -> Int64 {
        var value: AnyObject?
        try check(AXUIElementCopyAttributeValue(raw, "AXChildrenHash" as CFString, &value))
        return (value as? NSNumber)?.int64Value ?? 0
    }
    
    /// Hash that includes relative frame positions
    func childrenHashWithRelativeFrame() throws -> Int64 {
        var value: AnyObject?
        try check(AXUIElementCopyAttributeValue(raw, "AXChildrenHashWithRelativeFrameAttribute" as CFString, &value))
        return (value as? NSNumber)?.int64Value ?? 0
    }
}
```

**Use cases:**
- Efficiently detect if a subtree changed without full traversal
- Implement caching: only re-fetch when hash changes
- Track UI state changes

### 5. Hit Test Including Ignored Elements

**Current code** (`Element.swift:36-40`):
```swift
func hitTest(x: Float, y: Float) throws -> Element {
    var res: AXUIElement?
    try check(AXUIElementCopyElementAtPosition(raw, x, y, &res))  // Skips ignored elements!
    return try Element(raw: res.orThrow(...))
}
```

**New capability:**
```swift
func hitTestIncludingIgnored(x: Float, y: Float) throws -> Element {
    var res: AXUIElement?
    try check(_AXUIElementCopyElementAtPositionIncludeIgnored(raw, &res, CGPoint(x: CGFloat(x), y: CGFloat(y))))
    return try Element(raw: res.orThrow(...))
}
```

**Use case:** Find decorative/container elements that are normally hidden from accessibility

### 6. Performance Tuning APIs

```swift
extension Accessibility {
    /// Set global timeout for all AX operations (default 1500ms)
    static func setGlobalTimeout(milliseconds: Int) {
        _AXUIElementSetGlobalTimeout(Int32(milliseconds))
    }
    
    /// Enable secondary thread for AX operations (reduces main thread blocking)
    static func useSecondaryThread(_ enable: Bool) throws {
        try check(_AXUIElementUseSecondaryAXThread(enable))
    }
}
```

### 7. Get Window ID from Element

**Already exists** in `AXPrivate.h` and used in `Element.swift:122-126`
```swift
func window() throws -> Window {
    var id: CGWindowID = 0
    try Accessibility.check(_AXUIElementGetWindow(raw, &id))
    return .init(raw: id)
}
```
This is already implemented!

## Recommended Changes

### Add to `CAccessibilityControl/include/AXPrivate.h`:

```c
#ifndef AXPrivate_h
#define AXPrivate_h

#import <ApplicationServices/ApplicationServices.h>

// Already exists
AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outID);

// NEW: Batch hierarchy copy
AXError AXUIElementCopyHierarchy(
    AXUIElementRef element,
    CFArrayRef attributeNames,
    CFDictionaryRef options,
    CFArrayRef *hierarchy
);

// NEW: Remote token for element identification
CFDataRef _AXUIElementRemoteTokenCreate(AXUIElementRef element);
AXUIElementRef _AXUIElementCreateWithRemoteToken(CFDataRef token);

// NEW: Get internal element data
AXError _AXUIElementGetData(AXUIElementRef element, CFDataRef *outData, int32_t *outElementID);

// NEW: Hit test including ignored elements
AXError _AXUIElementCopyElementAtPositionIncludeIgnored(
    AXUIElementRef application,
    AXUIElementRef *outElement,
    CGPoint position
);

// NEW: Performance tuning
void _AXUIElementSetGlobalTimeout(int32_t milliseconds);
AXError _AXUIElementUseSecondaryAXThread(Boolean enable);

#endif
```

### Add private attribute names to `AccessibilityNames+Additions.swift`:

```swift
// Private attributes for efficient querying
var childrenHash: AttributeName<Int64> { "AXChildrenHash" }
var childrenHashWithRelativeFrame: AttributeName<Int64> { "AXChildrenHashWithRelativeFrameAttribute" }
var childrenInNavigationOrder: AttributeName<[Accessibility.Element]> { "AXChildrenInNavigationOrder" }
var childrenOrdered: AttributeName<[Accessibility.Element]> { "AXChildrenOrdered" }
var relativeFrame: AttributeName<CGRect> { "AXRelativeFrame" }
```

## Impact Summary

| Current Approach | Private API | Improvement |
|-----------------|-------------|-------------|
| `recursiveChildren()` - N IPC calls | `AXUIElementCopyHierarchy` - 1 call | ~100x fewer IPC calls |
| Fetch attributes one by one | `CopyMultipleAttributeValues` | ~10-20x fewer IPC calls |
| No element persistence | Remote tokens | Can identify elements across time |
| Full traversal to detect changes | `AXChildrenHash` | O(1) change detection |
| 1500ms default timeout | `SetGlobalTimeout` | Tunable for responsiveness |
| Main thread blocking | `UseSecondaryAXThread` | Non-blocking AX operations |

## Files to Modify

1. **BetterSwiftAX:**
   - `Sources/CAccessibilityControl/include/AXPrivate.h` - Add declarations
   - `Sources/AccessibilityControl/Element.swift` - Add new methods
   
2. **BetterSwiftAXAdditions:**
   - `AccessibilityNames+Additions.swift` - Add private attribute names
   - `AccessibilityElement+Additions.swift` - Replace `recursiveChildren()` with hierarchy API
