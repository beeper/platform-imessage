---
id: index
title: messages-deeplink-tester
created: 2026-01-27
summary: Entry point for this knowledge base.
modified: 2026-01-27
---

# messages-deeplink-tester

## Structure

```
└── (add docs here with {@id} references)
```

## Recent Activity

- 2026-01-27: Created knowledge base

## Overview

CLI tool for testing Messages app deep links and verifying auto-suppression behavior.

## Documentation

- {@tool-overview} - How to run and use the tester
- {@deeplinks} - iMessage deep link URL format
- {@auto-suppression} - How UIElement suppression works

## Reference Data

- {@test-guids} - Message GUIDs from Kishan conversation for testing

## Key Files

| File | Purpose |
|------|---------|
| `Sources/MessagesDeepLinkTester/main.swift` | CLI tool source |
| `type_changes.json` | Runtime log of type changes |
| `kishan_deeplinks.json` | Test deep link URLs |

## Quick Start

```bash
cd /Users/purav/Developer/Beeper/platform-imessage/src/SwiftServer/Sources/LSLauncherTool
swift run messages-deeplink-tester
```

## Known Issues

- {@suppression-latency-problem} - Notification-based auto-suppression is too slow to prevent dock icon flash
