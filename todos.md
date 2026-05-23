# TODOs

- [ ] improve readme, add screenshots

- [ ] publish to homebrew
- [ ] add example Swift script that consumes the library
- [ ] add example JS script that consumes the library

- [ ] improve permissions prompt, use <https://github.com/zats/permiso>
- [ ] replace SQLite w https://github.com/pointfreeco/sqlite-data and benchmark

- [ ] remove `.parity` when no longer needed
- [ ] consider folding callback from `PlatformAPI.onThreadSelected` into `subscribeToEvents`

- [ ] [bridgev2](https://github.com/mautrix/go) version for self hosting support
- [ ] run with node instead of electron <https://github.com/kabiroberai/node-swift/issues/4>

- [ ] review for races, `PlatformAPI.messagesController` is mutated without isolation
- [ ] add cross-process coordination when more than one process is driving Messages.app at the same time (e.g. Beeper Desktop + a separate CLI process, or two CLIs w secondary instance off)
- [ ] separate `UserDefaults` somehow so that CLI and other consumers don't share the prefs
- [ ] user manually killing the messages.app causes cli to not detect that ("Domain=NSOSStatusErrorDomain Code=-600 "procNotFound: no eligible process with specified descriptor"")
- [ ] improve misfire prevention and robustness
- [ ] when scheduled messages are actually sent, send a message update event
- [ ] perhaps move PlatformSDK to <https://github.com/TextsHQ/platform-sdk>

- cli
  - [ ] command to watch chat that prints new activity for just that chat, json new-line separated
  - [ ] use better library for repl?
  - [ ] autocomplete
  - [ ] tests

### Parity

- [ ] add delete message for me command
- [ ] add add/remove group participant command
- [ ] fix sending emoji reactions (🎉)
- [ ] add rename group title command
- [ ] add update group image command
- [ ] add schedule message command
- [ ] add draft message command
- [ ] add leave group command
- [ ] support rich text sending
- [ ] support sending multipart messages (image(s) with caption)
- [ ] fix parsing for multi-part messages w inline stickers
- [ ] [fix real time sync of message deletions (for self, undo send already works)](https://github.com/beeper/platform-imessage/pull/63)

### Done

- [x] publish to gh releases
- [x] publish to spm
- [x] transpile to pure Swift with TypeScript/Electron bindings
- [x] [add support for spinning up a discrete instance of Messages.app](https://github.com/beeper/platform-imessage/pull/65)
- [x] remove event-watching side effect from `PlatformAPI.getThreads(...)`. It currently bootstraps event watching from the first chat fetch (`cursor == nil`) via `EventWatcherLifecycle.shared.startBootstrapIfNecessary(...)`; a fetch function should only perform a single read and return data. Starting event watching from inside it makes calls non-idempotent. Fix by moving event-watcher bootstrap ownership to the caller/lifecycle layer, e.g. the existing explicit `startEventWatchingFromCurrentState` / `IMessageHost.startEventWatchingFromCurrentState` path.
- [x] fix receiving typing indicators on tahoe
- [x] fix graphic for old school tapback reactions (👍, ❤️) – should not be same as emoji reactions (like, heart)
- [x] cli messages/chats command: add pagination
- [x] add undo send CLI command
- [x] fix notify anyway on tahoe
- [x] fix unmute chat on tahoe
- instead of `thread_messages_refresh`
  - [x] new incoming messages should be state sync message upserts
  - [x] new added/removed reactions should be state sync message upserts/deletes (for the hidden reaction message) and a state sync message update (for the og message)
  - [x] messages edited should be state sync message updates
  - [x] messages getting read should be state sync message updates
- [x] when the user sends a message w tweets/links, when the link/tweet preview resolves, send a message update event
- [x] https://github.com/SwiftPackageIndex/PackageList/issues/new?template=add_package.yml
- cli
  - [x] resolve chat id as email/phone # if `any;-;` prefix isn't passed
  - [x] notarize before gh release and do universal binary/x86 target
  - [x] w system contacts, resolve phone #s and emails and populate `Thread.title`, `User.fullName`, `User.imgURL`
  - [x] format flag for yaml readable output
  - [x] one off command to print presence (dnd / dnd w notify) and typing status
  - [x] syntax highlight
- [x] add download attachment command
- [x] map all message edits
