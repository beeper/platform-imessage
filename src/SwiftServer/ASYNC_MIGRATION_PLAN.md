# SwiftServer Async/Await Migration Plan

This document outlines the issues with the current async/await implementation in SwiftServer and provides a comprehensive plan for migrating to proper Swift concurrency patterns using node-swift's native async support.

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current Architecture Problems](#current-architecture-problems)
3. [How node-swift Async Support Works](#how-node-swift-async-support-works)
4. [Detailed Issue Inventory](#detailed-issue-inventory)
5. [Migration Plan](#migration-plan)
6. [File-by-File Changes](#file-by-file-changes)
7. [Testing Strategy](#testing-strategy)

---

## Executive Summary

SwiftServer currently bridges async Swift code to Node.js using unsafe patterns that block threads. The main issues are:

1. **`unsafeBlockCurrentThreadUntilComplete`** - Uses semaphores to block threads waiting for async operations
2. **34+ `Thread.sleep` calls** - Blocks threads instead of using cooperative async delays
3. **Manual Promise resolution** - Uses DispatchQueue instead of node-swift's native async-to-Promise bridging
4. **Data races** - Uses `nonisolated(unsafe)` with semaphores unsafely

**node-swift now supports native async functions** that automatically convert to JavaScript Promises. This migration will eliminate thread blocking and properly leverage Swift's structured concurrency.

---

## Current Architecture Problems

### Problem 1: `unsafeBlockCurrentThreadUntilComplete`

**Location:** `Sources/SwiftServerFoundation/UnsafeSynchronousBridgeActor.swift:62-83`

```swift
public func unsafeBlockCurrentThreadUntilComplete<T>(
    @_implicitSelfCapture _ operation: @escaping () async throws -> T
) throws -> T {
    precondition(!Thread.isMainThread)
    precondition(!UnsafeSynchronousBridgeActor.isOnActorQueue())

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!

    Task.detached { @UnsafeSynchronousBridgeActor in
        defer { semaphore.signal() }
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
    }

    semaphore.wait()  // BLOCKS THE THREAD ENTIRELY
    return try result.get()
}
```

**Why this is bad:**
- Completely blocks the calling thread, wasting system resources
- Can deadlock if the async operation needs the blocked thread to make progress
- Violates Swift concurrency's cooperative threading model
- The `Task.detached` runs on a different executor, but the calling thread sits idle

**Used in 4 critical locations:**
1. `MessagesController.swift:73` - Terminating multiple Messages instances
2. `MessagesController.swift:88` - Creating MessagesApplication
3. `MessagesApplication.swift:435` - Opening deep links
4. `PromptAutomation.swift:76` - Confirming UNC prompts

### Problem 2: Synchronous `returnAsync` Pattern

**Location:** `Sources/SwiftServer/Messages/MessagesControllerWrapper.swift:20-45`

```swift
private static func returnAsync(
    on jsQueue: NodeAsyncQueue,
    function: StaticString = #function,
    _ action: @escaping () throws -> NodeValueConvertible  // SYNCHRONOUS!
) throws -> NodePromise {
    return try NodePromise { deferred in
        queue.async {  // Dispatches to a DispatchQueue
            let result = Result { try action() }  // Runs synchronously
            try? jsQueue.run {
                try deferred(result)
            }
        }
    }
}
```

**Why this is bad:**
- The `action` closure is **synchronous** (`() throws -> ...`), not async
- When `action` contains `Thread.sleep`, it blocks the entire DispatchQueue
- The queue is serial (`PassivelyAwareDispatchQueue`), so operations pile up
- This defeats the purpose of async - we're just moving blocking to a background thread

### Problem 3: 34 `Thread.sleep` Calls

**Location:** `Sources/SwiftServer/Messages/MessagesController.swift`

These block the thread instead of yielding cooperatively:

| Line | Duration | Purpose |
|------|----------|---------|
| 242 | variable | Misfire prevention fallback |
| 513 | 1.0s | Sync block delay |
| 516 | 0.1s | Sync block delay |
| 544 | 0.4s | Unknown |
| 632 | 0.75s | Wait for animation |
| 640 | 1.0s | Wait for animation |
| 648 | 0.75s | Wait for search |
| 654-656 | 0.05-0.1s | Polling loops |
| 659 | 0.2s | Skin tone picker |
| 736 | 0.5s | Unknown |
| 746-782 | configurable | UserDefaults delays |
| 1067 | 0.4s | Animation wait |
| 1164 | 3.0s | Address resolution |
| 1384 | 0.05s | Wait loop |

**Other files with `Thread.sleep`:**
- `Extensions.swift:13,22` - Legacy launch wait polling
- `Retry.swift:51` - Retry backoff
- `LSApplicationLauncher.swift:383` - App launch polling
- `LSLauncherCLI/main.swift:276,475,512,655,708` - Various waits
- `IMDatabaseTestBench/TestBench.swift:364-388` - Test delays

### Problem 4: Semaphore + nonisolated(unsafe) Data Races

**Locations:**
- `LSLauncherCLI/main.swift:484-496` - `nonisolated(unsafe) var nsApp`
- `LSLauncherCLI/main.swift:854-866` - `nonisolated(unsafe) var launchedApp`
- `LSApplicationLauncher.swift:400-410` - `nonisolated(unsafe) var resultApp`

Pattern:
```swift
let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var result: SomeType?  // UNSAFE!

someAsyncAPI { value in
    result = value  // Written from callback
    semaphore.signal()
}

semaphore.wait()
return result!  // Read from calling thread - DATA RACE
```

### Problem 5: RunLoop Busy-Wait Polling

**Locations:**
- `LSApplicationLauncher.swift:367,431`
- `LSLauncherCLI/main.swift:502,529`

```swift
while !condition && Date() < deadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))  // Busy wait
}
```

### Problem 6: DispatchQueue.main.sync Deadlock Risk

**Location:** `MessagesController.swift:493-508`

```swift
DispatchQueue.main.sync { ... }  // Can deadlock if called from main
try Self.queue.sync {
    Thread.sleep(forTimeInterval: 1.0)  // Blocks inside sync
}
```

---

## How node-swift Async Support Works

### Native Async Functions

**Location:** `/Users/purav/Developer/Beeper/node-swift/Sources/NodeAPI/NodeFunction.swift:59-60,111-115`

```swift
// Type aliases for async callbacks
public typealias AsyncCallback = @NodeActor (_ arguments: NodeArguments) async throws -> NodeValueConvertible
public typealias AsyncVoidCallback = @NodeActor (_ arguments: NodeArguments) async throws -> Void

// Convenience initializer - automatically wraps in NodePromise
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public convenience init(name: String = "", callback: @escaping AsyncCallback) throws {
    try self.init(name: name) { args in
        try NodePromise { try await callback(args) }  // Automatic!
    }
}
```

### NodePromise Async Extension

**Location:** `/Users/purav/Developer/Beeper/node-swift/Sources/NodeAPI/NodePromise.swift:97-111`

```swift
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NodePromise {
    public convenience init(body: @escaping @Sendable @NodeActor () async throws -> NodeValueConvertible) throws {
        try self.init { deferred in
            Task {
                let result: Result<NodeValueConvertible, Swift.Error>
                do {
                    result = .success(try await body())
                } catch {
                    result = .failure(error)
                }
                try deferred(result)
            }
        }
    }
}
```

### The NodeActor

**Location:** `/Users/purav/Developer/Beeper/node-swift/Sources/NodeAPI/NodeActor.swift`

**Critical insight:** `@NodeActor` is NOT a true single global actor. From the source:

> "This isn't *actually* a single global actor. Rather, its associated serial executor runs jobs on the task-local 'target' NodeAsyncQueue."

```swift
@globalActor public actor NodeActor {
    private init(target: NodeAsyncQueue.Handle?) {
        executor = NodeExecutor(defaultTarget: target)
    }

    // Different NodeAsyncQueues get different NodeActor instances
    private static nonisolated(unsafe) var cache: [UUID: Weak<NodeActor>] = [:]
    private static let lock = Lock()

    public static var shared: NodeActor {
        guard let target else { return defaultShared }
        let key = target.queue.instanceID
        return lock.withLock {
            if let item = cache[key]?.value { return item }
            let newActor = NodeActor(target: target)
            cache[key] = Weak(newActor)
            return newActor
        }
    }

    @TaskLocal static var target: NodeAsyncQueue.Handle?
}
```

**Implications for thread safety:**
- `@NodeActor` dispatches to whichever `NodeAsyncQueue` is the current target (stored in `@TaskLocal`)
- Different Node contexts (e.g., workers) would have different target queues
- Within a single Node.js context, calls are serialized on that context's queue
- Static state accessed from `@NodeActor` methods could race if there are multiple Node contexts
- For single-context apps (typical case), serialization is effectively guaranteed
- If you need safe static state across contexts, use a lock or actor-isolated storage

### Correct Usage Pattern

```swift
// In #NodeModule or NodeClass:
"myFunction": try NodeFunction { (arg1: String, arg2: Int) async throws -> String in
    // This is automatically wrapped in NodePromise
    // Swift async/await works natively here
    try await Task.sleep(nanoseconds: 500_000_000)  // Non-blocking!
    let result = try await someAsyncOperation()
    return result
}
```

JavaScript side:
```javascript
const result = await swiftModule.myFunction("hello", 42);
// Or: swiftModule.myFunction("hello", 42).then(result => ...)
```

---

## Detailed Issue Inventory

### Files Requiring Changes

| File | Issue Type | Severity | Changes Needed |
|------|------------|----------|----------------|
| `UnsafeSynchronousBridgeActor.swift` | Semaphore blocking | Critical | Delete/deprecate |
| `MessagesControllerWrapper.swift` | Sync closure pattern | Critical | Make async |
| `MessagesController.swift` | 34 Thread.sleep, sync methods | Critical | Full async conversion |
| `MessagesApplication.swift` | unsafeBlock usage | High | Make init async |
| `PromptAutomation.swift` | unsafeBlock usage | High | Make async |
| `LSApplicationLauncher.swift` | Semaphore, RunLoop, Thread.sleep | High | Async launch API |
| `LSLauncherCLI/main.swift` | Semaphore, nonisolated(unsafe), Thread.sleep | Medium | Async patterns |
| `Extensions.swift` | Thread.sleep polling | Medium | Async wait |
| `Retry.swift` | Thread.sleep | Medium | Task.sleep |
| `SwiftServer.swift` | Fire-and-forget Tasks | Low | Add error handling |
| `Logging.swift` | Fire-and-forget Tasks | Low | Add error handling |

### Thread.sleep Call Sites (Complete List)

**MessagesController.swift:**
- Lines: 242, 513, 516, 544, 632, 640, 648, 654, 655, 656, 659, 736, 746, 750, 753, 782, 1067, 1164, 1384

**Extensions.swift:**
- Lines: 13, 22

**Retry.swift:**
- Line: 51

**LSApplicationLauncher.swift:**
- Line: 383

**LSLauncherCLI/main.swift:**
- Lines: 276, 475, 512, 655, 708

**IMDatabaseTestBench/TestBench.swift:**
- Lines: 364, 369, 373, 377, 388

---

## Migration Plan

### Phase 1: Core Infrastructure (Smallest Testable Change) ✅ DONE

**Goal:** Enable async closures in `returnAsync` without breaking existing code.

**Completed:**
1. Added async `returnAsync` overload to `MessagesControllerWrapper`
2. Added async `performAsync` overload
3. Converted `isValid` to use async pattern

```swift
private func returnAsync(
    _ action: @escaping () async throws -> NodeValueConvertible
) throws -> NodePromise {
    try NodePromise { try await action() }
}

private func performAsync(
    _ action: @escaping () async throws -> Void
) throws -> NodePromise {
    try returnAsync {
        try await action()
        return undefined
    }
}

@NodeMethod func isValid() throws -> NodeValueConvertible {
    try returnAsync { () async in self.controller.isValid }
}
```

**Testing:** Call `controller.isValid()` from Node.js - should return a Promise that resolves to a boolean.

### Phase 2: Convert MessagesController Methods

**Goal:** Make MessagesController methods async, replace Thread.sleep with Task.sleep.

1. Change method signatures from sync to async
2. Replace `Thread.sleep(forTimeInterval: x)` with `try await Task.sleep(nanoseconds: UInt64(x * 1_000_000_000))`
3. Update `MessagesControllerWrapper` to call async versions

### Phase 3: Remove unsafeBlockCurrentThreadUntilComplete

**Goal:** Eliminate all semaphore-based blocking.

1. Make `MessagesController.init` async or use factory pattern
2. Make `MessagesApplication.init` async
3. Make `PromptAutomation` methods async
4. Delete `UnsafeSynchronousBridgeActor.swift` or mark deprecated

### Phase 4: Fix LSLauncher Patterns

**Goal:** Proper async app launching.

1. Replace semaphore patterns with `withCheckedContinuation`
2. Replace `RunLoop.run(until:)` polling with async observation
3. Remove `nonisolated(unsafe)` data races

### Phase 5: Cleanup

1. Add proper error handling to fire-and-forget Tasks
2. Remove unused synchronous overloads
3. Update tests

---

## File-by-File Changes

### `MessagesControllerWrapper.swift`

**Implemented (Phase 1):**

```swift
// Async overloads - use node-swift's native async-to-Promise bridging
private func returnAsync(
    _ action: @escaping () async throws -> NodeValueConvertible
) throws -> NodePromise {
    try NodePromise { try await action() }
}

private func performAsync(
    _ action: @escaping () async throws -> Void
) throws -> NodePromise {
    try returnAsync {
        try await action()
        return undefined
    }
}

// Usage - explicitly mark closure as async to select async overload
@NodeMethod func isValid() throws -> NodeValueConvertible {
    try returnAsync { () async in self.controller.isValid }
}
```

**Why no counter/logging in async version:**
- The sync version uses `queueCounter` to correlate logs for operations on `Self.queue`
- The async version doesn't use that queue - it goes through node-swift's native handling
- No need for a lock since `@NodeActor` provides serialization within a Node context

### `MessagesController.swift`

```swift
// CHANGE: Make methods async
func toggleThreadRead(threadID: String, read: Bool) async throws {
    // ... existing logic ...
    try await Task.sleep(nanoseconds: 500_000_000)  // Instead of Thread.sleep
    // ...
}

// CHANGE: Make init async or use factory
static func create(reportToSentry: @escaping (String) -> Void) async throws -> MessagesController {
    // Remove unsafeBlockCurrentThreadUntilComplete calls
    let application = try await MessagesApplication(strategy: .puppetInstance, ...)
    // ...
}
```

### `UnsafeSynchronousBridgeActor.swift`

```swift
// DEPRECATE or DELETE
@available(*, deprecated, message: "Use async/await directly with node-swift")
public func unsafeBlockCurrentThreadUntilComplete<T>(...) throws -> T { ... }
```

---

## Testing Strategy

### Unit Tests

1. Test async `returnAsync` returns valid NodePromise
2. Test Task.sleep doesn't block other operations
3. Test error propagation through async chain

### Integration Tests

1. Test MessagesController methods work end-to-end from Node.js
2. Test concurrent operations don't block each other
3. Test cancellation propagates correctly

### Performance Tests

1. Measure thread utilization before/after
2. Measure response latency for operations
3. Verify no thread pool exhaustion under load

### Manual Testing Checklist

- [ ] Send message works
- [ ] Reactions work
- [ ] Thread read/unread works
- [ ] Typing indicators work
- [ ] Edit/unsend works
- [ ] Thread deletion works
- [ ] App launch/termination works
- [ ] Deep links work

---

## References

- node-swift repository: `/Users/purav/Developer/Beeper/node-swift`
- Key node-swift files:
  - `Sources/NodeAPI/NodeFunction.swift` - Async function support
  - `Sources/NodeAPI/NodePromise.swift` - Promise bridging
  - `Sources/NodeAPI/NodeActor.swift` - Thread safety
  - `Sources/NodeAPI/NodeAsyncQueue.swift` - Queue management
- Swift Concurrency documentation: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html
