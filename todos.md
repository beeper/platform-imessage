# TODOs

- [ ] improve readme, add screenshots
- [x] publish to gh releases
- [x] publish to spm
- [ ] https://github.com/SwiftPackageIndex/PackageList/issues/new?template=add_package.yml
- [ ] publish to homebrew
- [ ] add example Swift script that consumes the library
- [ ] add example JS script that consumes the library

- [ ] cli: w system contacts, resolve phone #s and emails and populate Thread.title, User.fullName, User.imgURL
- [ ] cli: resolve thread id as email/phone # if `any;-;` prefix isn't passed
- [ ] cli: notarize before gh release and do universal binary/x86 target
- [ ] cli: one off command to print presence (dnd / dnd w notify) and typing status

- [ ] review for races, `PlatformAPI.messagesController` is mutated without isolation

- [ ] improve permissions prompt, use <https://github.com/zats/permiso>
- [ ] tests for the cli
- [ ] remove `.parity` when no longer needed

- [ ] [bridgev2](https://github.com/mautrix/go) version for self hosting support
- [ ] run with node instead of electron <https://github.com/kabiroberai/node-swift/issues/4>

- [ ] add cross-process coordination when more than one process is driving Messages.app at the same time (e.g. Beeper Desktop + a separate CLI process, or two CLIs). Within a single process, IMessage is intentionally singleton-only.
- [ ] store UserDefaults in dataDirPath
- [ ] `thread_messages_refresh` events should be state sync message upserts

- [x] transpile to pure Swift with TypeScript/Electron bindings
- [x] [add support for spinning up a discrete instance of Messages.app](https://github.com/beeper/platform-imessage/pull/65)
- [x] remove event-watching side effect from `PlatformAPI.getThreads(...)`. It currently bootstraps event watching from the first thread fetch (`cursor == nil`) via `EventWatcherLifecycle.shared.startBootstrapIfNecessary(...)`; a fetch function should only perform a single read and return data. Starting event watching from inside it makes calls non-idempotent. Fix by moving event-watcher bootstrap ownership to the caller/lifecycle layer, e.g. the existing explicit `startEventWatchingFromCurrentState` / `IMessageHost.startEventWatchingFromCurrentState` path.

- [ ] improve misfire prevention and robustness

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
- [ ] map all message edits
- [ ] fix parsing for multi-part messages w inline stickers
- [ ] [fix real time sync of message deletions (for self, undo send already works)](https://github.com/beeper/platform-imessage/pull/63)
- [x] fix receiving typing indicators on tahoe
- [x] fix graphic for old school tapback reactions (👍, ❤️) – should not be same as emoji reactions (like, heart)
- [x] cli messages/threads command: add pagination
- [x] add undo send CLI command
- [x] fix notify anyway on tahoe
- [x] fix unmute thread on tahoe
