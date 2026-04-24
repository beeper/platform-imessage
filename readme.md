# platform-imessage

A standalone JS library and CLI that lets you and your agents send/receive messages and fully automate iMessage locally on your Mac.

Reads `chat.db` and works with automation and accessibility APIs. Designed to run with [System Integrity Protection (SIP)](https://en.wikipedia.org/wiki/System_Integrity_Protection) enabled since it does not hook into low level private APIs or make any network calls. Uses your Apple ID logged in to Messages.app. ~95% feature parity (reactions, threaded replies, edit message, undo send, typing indicators, rich text message formatting etc.) on macOS Tahoe.

This also powers the iMessage integration on [Beeper](https://www.beeper.com/download) for macOS.

Native code in Swift is exposed to JS via NAPI/[node-swift](https://github.com/kabiroberai/node-swift).

## Usage


1. Setup:
```sh
git clone https://github.com/beeper/platform-imessage
cd platform-imessage
yarn
yarn build:swift --debug --standalone
yarn build:cli
yarn cli authorize # authorize permissions like Accessibility/Automation/Contacts
```

2. Run one-off commands:
```sh
yarn cli current-user                                                                    # fetch logged in user
yarn cli threads                                                                         # fetch chats
yarn cli messages any;-;sjobs@apple.com                                                  # fetch messages for an existing chat

yarn cli send any;-;sjobs@apple.com "hello from shell"                                   # text an email
yarn cli send any;-;+14155551234 "hello from shell"                                      # text a phone number

yarn cli send-file any;-;+14155551234 ./image.png                                        # send a file

yarn cli create-thread +14155551234 --message "hey this is steve"                        # start a new chat with a number or email
yarn cli create-thread +15551234567 +15557654321 --message "new group"                   # create a group chat
yarn cli reply any;-;+14155551234 C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 "sounds good"     # reply to an existing message
yarn cli reply-file any;-;+14155551234 C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 ./doc.pdf    # send a file as a reply
yarn cli react any;-;+14155551234 C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 laugh             # haha react to a message
yarn cli react any;-;+14155551234 C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 heart             # heart a message
yarn cli unreact any;-;+14155551234 C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 laugh           # remove laugh from message

yarn cli edit any;-;+14155551234 C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 "updated text"     # edit a message

yarn cli search "project status"                                                         # search messages

yarn cli select-thread any;-;sjobs@apple.com                                             # select chat in messages.app
yarn cli typing any;-;sjobs@apple.com on                                                 # send typing indicator

yarn cli mark-read any;-;sjobs@apple.com
yarn cli mark-unread any;-;sjobs@apple.com
yarn cli mute any;-;sjobs@apple.com
yarn cli unmute any;-;sjobs@apple.com
yarn cli notify-anyway any;-;sjobs@apple.com                                             # if the recipient is on DND, hit the "notify anyway" button if present
yarn cli delete-thread any;-;sjobs@apple.com                                             # delete the entire chat
```

Or open the shell with `yarn cli`:

```sh
imessage> messages any;-;sjobs@apple.com
imessage> send any;-;sjobs@apple.com "hello from shell"
imessage> help
imessage> help create-thread
imessage> quit
```

The shell will automatically subscribe to real time events (incoming messages etc.) unless you pass `--no-events`

> [!NOTE]
> Commands you run are recorded in plain text to `.cli.history.json` (next to the CLI bundle) for arrow-up recall. This includes the full text of any messages sent via `send`/`reply`/`edit`. Delete the file at any time to clear history.

---

<details>
<summary>Old instructions excerpt</summary>

> **Note**
>
> This is a snippet from our internal documentation shared as a reference.
> You won't be able to run this project with Beeper Desktop.

`platform-imessage` implements local iMessage support on macOS. This requires
various permissions that must be granted to the app. There are various pitfalls
with this:

<!-- prettier-ignore -->
> [!IMPORTANT]
> When adding a local iMessage account to Beeper, you'll be prompted for
> several permissions. One of them is "Accessibility", which you need to grant
> in a System Settings window that the app opens for you. **In development,
> grant this permission to your terminal program, text editor, or wherever
> you're running `yarn dev` from INSTEAD of Beeper or Electron.**

<!-- prettier-ignore-->
> [!TIP]
> If you're having trouble granting permissions to the app, try running:
>
> ```
> tccutil reset All com.github.Electron
> ```
>
> This completely wipes away the permission state of the app with that bundle
> identifier in the "Privacy & Security" section of System Settings, which gives
> you a clean slate to work with. If that still doesn't work:
>
> * Try passing the bundle ID of your terminal emulator, text editor, or
>   whatever you run `yarn dev` in to `tccutil` instead of
>   `com.github.Electron`. Example bundle identifiers:
>    * iTerm2: `com.googlecode.iterm2`
>    * Ghostty: `com.mitchellh.ghostty`
>    * VS Code: `com.microsoft.VSCode`
>    * Cursor: `com.todesktop.230313mzl4w4u92` (yes, actually)
> * Try running any relevant `tccutil` commands, completely quitting and
>   restarting all apps involved, and trying again.
> * Try rebooting after running the `tccutil` command.

macOS examines the ultimately "responsible" process when deciding whether
permissions are granted or not. Because `yarn dev` (and therefore Electron) are
subprocesses of your terminal/text editor and the kernel is unable to know that
you ran the command yourself, the permissions must be granted there instead of
Electron itself. (This is only relevant in a development environment.)

</details>

## License

[MIT](./license.txt)

## Related

- [beeper/imessage](https://github.com/beeper/imessage)
- [mautrix/imessage](https://github.com/mautrix/imessage)
