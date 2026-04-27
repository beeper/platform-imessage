# TODOs

- [ ] improve readme, add screenshots
- [ ] publish to npm
- [ ] publish to homebrew
- [ ] publish to gh releases
- [ ] add example JS+Swift script that consumes the library

- [ ] cli: w system contacts, resolve phone #s and emails and populate Thread.title, User.fullName, User.imgURL
- [ ] cli: resolve thread id as email/phone # if `any;-;` prefix isn't passed

- [ ] improve permissions prompt, use <https://github.com/zats/permiso>
- [ ] tests for the cli
- [ ] migrate parity test from worktree-of-main reference to snapshot-based regression once Swift fixture-snapshot port is live; remove `.parity/check-swift-mapper-parity.mjs` when no longer needed

- [ ] [bridgev2](https://github.com/mautrix/go) version for self hosting support
- [ ] run with node instead of electron <https://github.com/kabiroberai/node-swift/issues/4>

- [ ] add cross-process coordination when more than one process is driving Messages.app at the same time (e.g. Beeper Desktop + a separate CLI process, or two CLIs). Within a single process, IMessage is intentionally singleton-only.
- [ ] store UserDefaults in dataDirPath
- [x] transpile to pure Swift with TypeScript/Electron bindings
- [x] [add support for spinning up a discrete instance of Messages.app](https://github.com/beeper/platform-imessage/pull/65)

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
- [x] fix graphic for old school tapback reactions (👍, ❤️) – should not be same as emoji reactions (like, heart)
- [x] cli messages/threads command: add pagination
- [x] add undo send CLI command
