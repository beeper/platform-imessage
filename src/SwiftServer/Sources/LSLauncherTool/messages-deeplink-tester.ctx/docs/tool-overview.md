---
id: tool-overview
title: Messages Deep Link Tester
created: 2026-01-27
summary: CLI tool for testing Messages app deep links and auto-suppression
modified: 2026-01-27
---

# Messages Deep Link Tester

TODO: Add content

## Purpose

A focused CLI tool for testing Messages app (com.apple.MobileSMS) deep links and verifying that auto-suppression keeps the app hidden from the Dock.

## Location

```
/Users/purav/Developer/Beeper/platform-imessage/src/SwiftServer/Sources/LSLauncherTool/Sources/MessagesDeepLinkTester/main.swift
```

## Features

- Type observer and auto-suppress enabled by default on startup
- Opens iMessage deep links and monitors for type changes
- Logs all type changes to `type_changes.json` continuously
- Measures suppression latency (time from deep link open to UIElement)

## Running

```bash
cd /Users/purav/Developer/Beeper/platform-imessage/src/SwiftServer/Sources/LSLauncherTool
swift run messages-deeplink-tester
```

## Monitoring

Watch type changes in another terminal:
```bash
tail -f type_changes.json
```

## Dependencies

Uses the LSLauncher library which provides:
- `LSApplicationLauncher` - private LaunchServices APIs
- `LSTypeObserver` - monitors application type changes via LS notifications

See {@deeplinks} for test URLs and {@auto-suppression} for how suppression works.
