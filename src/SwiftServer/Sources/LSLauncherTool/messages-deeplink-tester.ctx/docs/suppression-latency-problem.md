---
id: suppression-latency-problem
title: Suppression Latency Problem
created: 2026-01-27
summary: Notification-based auto-suppression is too slow to prevent dock icon flash
modified: 2026-01-27
---

# Suppression Latency Problem

TODO: Add content

## Problem Statement

When deep links are sent to a Messages instance in UIElement mode, the app transitions to Foreground before the auto-suppression can react. This causes:

1. **Dock icon flash** - The Messages icon appears in the dock, even if briefly
2. **Multiple dock icons** - Under rapid deep link stress, dozens of dock icons can accumulate
3. **Unresponsive instances** - Rapid foreground/suppress cycling can leave instances in a bad state

## Observed Behavior

Stress test results (40 iterations, 100ms delay):

```
=== STRESS TEST RESULTS ===
  Total time: 4.75s
  Successful sends: 40
  Failed sends: 0
  Type change events: 78
  Foreground transitions: 39
  UIElement suppressions: 39
  Foreground detected during send: 39

⚠️  Auto-suppression may be too slow!

Suppression Latency:
  Min: 0.1ms
  Avg: 74.0ms
  Max: 298.8ms
```

Every single deep link send (39/40) caused a Foreground transition that was detected.

## Timeline of Events

For each deep link sent:

1. `t=0ms` - Deep link sent via NSAppleEventDescriptor to Messages instance
2. `t=?ms` - Messages internally processes the URL and promotes itself to Foreground
3. `t=?ms` - macOS renders the dock icon (happens immediately on Foreground transition)
4. `t=?ms` - LaunchServices generates `applicationTypeChanged` notification (code 0x231)
5. `t=?ms` - Notification delivered to our observer queue
6. `t=~74ms avg` - Observer callback fires, we call `setApplicationMode(.uiElement)`
7. `t=~74ms+` - Dock icon disappears

The dock icon is visible for the entire window between steps 3 and 7.

## Root Cause

The suppression mechanism is **reactive**, not **preemptive**:

- We only learn about the Foreground transition AFTER it happens
- By the time we receive the notification, macOS has already rendered the dock icon
- The LaunchServices notification system has inherent latency (IPC, queue scheduling)

## Info Dictionary Contents

From Hopper analysis, the notification info dictionary contains:

| Key | Value | Description |
|-----|-------|-------------|
| `ApplicationType` | "Foreground" / "UIElement" | The NEW type (after transition) |
| `LSPreviousValue` | "UIElement" / "Foreground" | The OLD type (before transition) |
| `ChangeCount` | Integer | Monotonic counter |
| `LSASN` | String | Application serial number |

There is no way to intercept or block the transition before it happens.

## Visual Evidence

Under stress test conditions, the dock shows a row of Messages icons:

![Dock with multiple Messages icons](CleanShot 2026-01-27 at 10.37.47@2x.png)

Each icon represents a moment when Messages transitioned to Foreground. Even though suppression eventually fires, the icons persist because:

1. macOS dock rendering is immediate on Foreground transition
2. The rapid cycling may confuse the dock's internal state
3. Some instances may become unresponsive mid-transition

## Secondary Issue: Zombie Instances

After stress testing, instances can become:

- Unresponsive (don't respond to AppleEvents)
- Invisible in Finder's Force Quit dialog
- Stuck with permanent dock icons
- Only killable via `pkill -9 MobileSMS`

This suggests the rapid Foreground→UIElement cycling corrupts some internal application state.

## Key Insight

The notification-based approach can only **react** to type changes, not **prevent** them. The app decides to become Foreground internally when processing the deep link - we have no hook to intercept this decision before it happens.

## Alternative Theory: AppleEvent Blocking

A more likely explanation: when an AppleEvent is sent to Messages, the app becomes "busy" processing the deep link. During this busy period:

1. The app may not respond to new AppleEvents
2. macOS may interpret the next deep link send as requiring a NEW instance
3. This spawns additional dock icons / app instances

Evidence to investigate:
- Does `isFinishedLaunching` change during deep link processing?
- Does instance count increase during rapid sends?
- Does the AppleEvent send itself block/hang for a period?

## Investigation Tools

The tester now includes:

1. **Async stress test** (`[a]`) - Sends deep links on background thread with continuation, monitors:
   - Send duration (how long the AppleEvent takes to return)
   - `isFinishedLaunching` state before/after
   - Instance count before/after (detects new instance spawning)

2. **Zombie cleanup** (`[k]`) - Detects and kills unresponsive instances:
   - Sends ping AppleEvent with 2s timeout
   - Force-terminates non-responsive instances
