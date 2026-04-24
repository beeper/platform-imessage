# TODOs

- [ ] contacts: use SwiftServer to resolve phone #s and emails and populate Thread.title, User.fullName, User.imgURL
- [ ] improve readme, add screenshots
- [ ] publish to npm
- [ ] add example script that consumes the library

- [ ] improve permissions prompt, use <https://github.com/zats/permiso>
- [ ] tests for the cli
- [ ] transpile to pure Swift with TypeScript/Electron bindings
  - [ ] made bridgev2 version for self hosting support
- [ ] run with node instead of electron <https://github.com/kabiroberai/node-swift/issues/4>

- [ ] add support for spinning up a discrete instance of Messages.app
- [ ] fix parsing for multi-part messages w inline stickers
- [ ] fix graphic for old school tapback reactions (👍, ❤️) – should not be same as emoji reactions (like, heart)
- [ ] fix sending emoji reactions (🎉)
- [ ] [fix real time sync of message deletions (for self, undo send already works)](https://github.com/beeper/platform-imessage/pull/63)
- [ ] add handling for multiple instances

- [ ] store UserDefaults in dataDirPath
