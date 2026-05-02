# platform-imessage

A standalone Swift library and CLI that lets you and your agents send/receive messages and fully automate iMessage locally on your Mac.

Reads `chat.db` and works with automation and accessibility APIs – similar to [Codex Computer Use](https://developers.openai.com/codex/app/computer-use) but surgical and faster. Designed to run with the normal macOS security model ([System Integrity Protection (SIP)](https://en.wikipedia.org/wiki/System_Integrity_Protection) enabled) since it does not hook into low-level private APIs or make any network calls. Uses your Apple ID logged in to Messages.app. ~95% feature parity on macOS Tahoe.

This library powers the iMessage integration on [Beeper](https://www.beeper.com/download) for macOS. N-API bindings for Node/Electron are powered by [node-swift](https://github.com/kabiroberai/node-swift).

**What it won't do**: expose more features if you disable SIP, allow automating multiple iMessage accounts, work on Windows/Linux. Also see [TODOs](./todos.md).

## Features

| Feature | platform-imessage | BlueBubbles (SIP enabled) |
| --- | --- | --- |
| Read chats and messages from `chat.db` | ✅ | ✅ |
| Realtime message updates | ✅ | ✅ |
| Receive tapbacks, stickers, mentions, replies | ✅ | ✅ |
| Send text messages | ✅ | ✅ |
| Send attachments | ✅ | ✅ |
| Create 1:1 chats | ✅ | ✅ |
| Create group chats | ✅ | ❌<sup>*</sup> |
| Send replies / quoted messages | ✅ | ❌<sup>*</sup> |
| Send / remove tapbacks/reactions | ✅ | ❌<sup>*</sup> |
| Edit sent messages | ✅ | ❌<sup>*</sup> |
| Undo send | ✅ | ❌<sup>*</sup> |
| Mark chats read / unread in Messages.app | ✅ | ❌<sup>*</sup> |
| Send typing indicators | ✅ | ❌<sup>*</sup> |
| Notify anyway / Focus bypass | ✅ | ❌<sup>*</sup> |
| Search messages | ✅ | Partial<sup>*</sup> |
| Group management: rename, add/remove members, leave, update photo | Planned | ❌<sup>*</sup> |
| Rich sends: effects, subjects, attachment captions | Planned | ❌<sup>*</sup> |
| Self-hosted relay, REST API, push notifications | No | ✅ |

<sup>*</sup> BlueBubbles supports this through its Private API helper, which requires disabling SIP.

## Usage

1. Setup:
```sh
git clone https://github.com/beeper/platform-imessage
cd platform-imessage
yarn
yarn cli # launches authorization flow (Accessibility, Contacts, Messages Data, Automation) and then the REPL
```

2. Run one-off commands:
```sh
yarn cli current-user                                                                   # fetch logged-in user
yarn cli threads                                                                        # fetch chats
yarn cli messages 'any;-;sjobs@apple.com'                                               # fetch messages for an existing chat

yarn cli send 'any;-;sjobs@apple.com' "hello from shell"                                # text an email
yarn cli send 'any;-;+14155551234' "hello from shell"                                   # text a phone number

yarn cli send-file 'any;-;+14155551234' ./image.png                                      # send a file

yarn cli create-thread +14155551234 --message "hey this is steve"                       # start a new chat with a number or email
yarn cli create-thread +15551234567 +15557654321 --message "new group"                  # create a group chat
yarn cli reply 'any;-;+14155551234' C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 "sounds good"  # reply to an existing message
yarn cli reply-file 'any;-;+14155551234' C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 ./doc.pdf  # send a file as a reply
yarn cli react 'any;-;+14155551234' C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 laugh          # haha react to a message
yarn cli react 'any;-;+14155551234' C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 heart          # heart a message
yarn cli unreact 'any;-;+14155551234' C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 laugh        # remove laugh from message

yarn cli edit 'any;-;+14155551234' C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 "updated text"  # edit a message

yarn cli search "project status"                                                        # search messages

yarn cli select-thread 'any;-;sjobs@apple.com'                                          # select chat in messages.app
yarn cli typing 'any;-;sjobs@apple.com' on                                              # send typing indicator

yarn cli mark-read 'any;-;sjobs@apple.com'
yarn cli mark-unread 'any;-;sjobs@apple.com'
yarn cli mute 'any;-;sjobs@apple.com'
yarn cli unmute 'any;-;sjobs@apple.com'
yarn cli notify-anyway 'any;-;sjobs@apple.com'                                          # if the recipient is on DND, hit the "notify anyway" button if present
yarn cli delete-thread 'any;-;sjobs@apple.com'                                          # delete the entire chat
```

Or open the shell with `yarn cli`:

```sh
imessage> messages any;-;sjobs@apple.com
imessage> send any;-;sjobs@apple.com "hello from shell"
imessage> help
imessage> help create-thread
imessage> quit
```

The shell will automatically subscribe to real-time events (incoming messages, etc.) unless you pass `--no-events`.

> [!NOTE]
> For arrow-up recall, in development, commands you run are recorded in plain text to `.cli.history.json` at the repo root. This includes the plaintext of any messages sent via `send`/`reply`/`edit`. Released builds do not persist shell history unless `IMESSAGE_CLI_HISTORY_FILE` is set.

## Swift Package Manager

Requirements: macOS 11 or later, Swift 5.9 or later

```swift
dependencies: [
    .package(url: "https://github.com/beeper/platform-imessage.git", from: "0.1.0"),
]
```

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "IMessage", package: "platform-imessage"),
        ]
    ),
]
```

## JavaScript/TypeScript Usage

1. Set up with:
```
yarn build:swift --debug --standalone
yarn build:cli:js
```

2. Run with `yarn cli:js`. Also see [`src/cli/main.ts`](./src/cli/main.ts)

## License

[MIT](./license.txt)

## Related

- [beeper/imessage](https://github.com/beeper/imessage) – Matrix bridge that connects to Apple servers directly by identifying as an iMessage-capable Apple device
- [mautrix/imessage](https://github.com/mautrix/imessage) – Matrix bridge that has a few different backends (SIP-disabled private APIs, BlueBubbles server, etc.)
- [pypush](https://github.com/JJTech0130/pypush) – Original tech behind beeper/imessage 
- [rustpush](https://github.com/OpenBubbles/rustpush) – Rust port of pypush
