# iMessage Native Client Example

A lightweight macOS 14+ SwiftUI example app that uses the root `IMessage` Swift package directly.

## Run

From this example directory:

```sh
cd examples/IMessageNativeClient
swift run imessage-native-client
```

Or from the repository root:

```sh
swift run --package-path examples/IMessageNativeClient imessage-native-client
```

The example is intentionally its own Swift package so it can require macOS 14 and depend on UI-only packages without changing the root library package. It is an SPM executable rather than a signed `.app` bundle, so macOS permissions are granted to the launching process (for example Terminal, iTerm, or the Swift toolchain host), not to a packaged app bundle.

## What it supports

- Permissions checklist for Accessibility, Messages Data, Automation, and optional Contacts access.
- Existing thread list from `chat.db` with Contacts-backed display names when available.
- Message loading for the selected thread, with older pages loaded as you scroll upward.
- Message reactions under messages.
- Text sends and single-file attachment sends through Messages.app.
- Live refresh via the platform-imessage event watcher.
- Raw event log panel with pretty-printed JSON rendered by CodeEditorView.

## Notes

- Requires macOS 14 or later.
- Uses the existing `IMessageHost.bootstrapWithOptions` flow with a stable Application Support data directory.
- Uses a secondary Messages.app instance by default, matching the CLI default.
- This is an example client only; app bundle packaging, signing, new-chat creation, replies, editing, typing indicators, mute/read state management, and search are intentionally out of scope for v1.
