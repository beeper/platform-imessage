# platform-imessage

`platform-imessage` is the iMessage integration in Beeper Desktop on macOS. It's built on the deprecated [Platform SDK](https://github.com/textshq/platform-sdk).

## Getting Started

**It is not possible to use local builds with Beeper Desktop.** You can still interact with this project as a library, see [texthsq/platform-test-lib](https://github.com/textshq/platform-test-lib) as an example how Platform SDK can be used.

<details>
<summary>Instructions excerpt</summary>

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

## SwiftServer

SwiftServer exposes Swift functions to JS via
NAPI/[node-swift](https://github.com/kabiroberai/node-swift) and handles all
invocation of native Apple methods.

### Quirks

- Transparent thread merging: iMessage has separate threads for each
  address/sender ID (email or phone #) but transparently merges threads
  belonging to the same contact in the UI. Texts app shows separate threads and
  performs no merging. Imagine if we had two threads, stevejobs@apple.com and
  sjobs@apple.com. When calling a deep link to select either thread, sometimes
  it'll select the thread in the sidebar, other times it'd create a new compose
  cell. The logic is unknown. ![Compose cell](images/compose-cell.png)

- `MessagesController.pasteFileInBodyField`: On Big Sur, using
  `pasteboard.setString(fileURL.relativeString, forType: .fileURL)` doesn't
  paste the file itself but a link. Monterey has intended behavior.

- `elements.selectedThreadCell` is nil after pin/unpin because no cells are
  selected. `imessage://open?message-guid=` will not select the thread in
  sidebar (`elements.selectedThreadCell == nil`) if it's already open but
  `imessage://open?address=` will.

- After `elements.searchField` was clicked: `elements.conversationsList` will be
  nil, selected item in sidebar will not always be reflective of the messages
  list, calling a deep link will not update sidebar but only the messages list,
  `CKLastSelectedItemIdentifier` won't be updated.

### Building

```sh
# for debugging:
rm binaries/*/libNodeAPI.dylib # needed only when you get ENOENT
bun run build:swift --debug --watch

# for shipping to prod:
bun run build:swift
```

### Testing

```sh
node src/SwiftServer/test-script.js
electron src/SwiftServer/test-script.js
```

## License

[MIT](./license.txt)