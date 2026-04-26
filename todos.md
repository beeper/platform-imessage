# TODOs

- [ ] contacts: use SwiftServer to resolve phone #s and emails and populate Thread.title, User.fullName, User.imgURL
- [ ] improve readme, add screenshots
- [ ] publish to npm
- [ ] add example script that consumes the library

- [ ] improve permissions prompt, use <https://github.com/zats/permiso>
- [ ] tests for the cli
- [x] transpile to pure Swift with TypeScript/Electron bindings
  - [ ] made bridgev2 version for self hosting support
- [ ] migrate parity test from worktree-of-main reference to snapshot-based regression once Swift fixture-snapshot port is live; remove `.parity/check-swift-mapper-parity.mjs` when no longer needed
- [ ] run with node instead of electron <https://github.com/kabiroberai/node-swift/issues/4>

- [ ] [add support for spinning up a discrete instance of Messages.app](https://github.com/beeper/platform-imessage/pull/65)
- [ ] add handling for multiple instances of MessagesController (Beeper Desktop + CLI running at the same time)
- [ ] store UserDefaults in dataDirPath

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
- [ ] fix graphic for old school tapback reactions (👍, ❤️) – should not be same as emoji reactions (like, heart)
- [ ] [fix real time sync of message deletions (for self, undo send already works)](https://github.com/beeper/platform-imessage/pull/63)
- [x] cli messages/threads command: add pagination
- [x] add undo send CLI command
