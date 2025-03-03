# platform-imessage

This repo uses [Git LFS](https://git-lfs.github.com/) to host compiled binaries.

## Getting Started

Please see
[the instructions in the desktop repo's README](https://github.com/beeper/beeper-desktop-new#platform-imessage).
Old instructions kept here for posterity:

[beeper-desktop-new]: https://github.com/beeper/beeper-desktop-new/
[bdn-imsg-dependency]: https://github.com/beeper/beeper-desktop-new/
[xcode-mas]: https://apps.apple.com/us/app/xcode/id497799835
[rust]: https://www.rust-lang.org/
[rustup]: https://rustup.rs/
[platformapi-subclass]:
  https://github.com/beeper/platform-imessage/blob/a53a113e599b122c8119041d57cbb5de1d8ae348/src/api.ts#L44
[rustserver]: ./src/RustServer/
[applescriptserver]: ./src/AppleScriptServer/
[swiftserver]: ./src/SwiftServer/

<details>
  <summary>Old Instructions</summary>

<!-- prettier-ignore-->
> [!TIP]
> `yarn` may be freely substituted for `bun` in the commands below, as we're
> merely interested in delegating to `package.json` scripts.

1. Make sure you have [Xcode][xcode-mas] and a stable [Rust] toolchain
   installed.

   An easy way to install Rust is via [Rustup], which can be installed via e.g.
   `brew install rustup`. If you already have Rustup installed, you can run
   `rustup update` to make sure your toolchain is up-to-date.

2. **In `beeper-desktop-new`'s `package.json`,** re-point [the
   `@beeper/platform-imessage` entry][bdn-imsg-dependency] in
   `optionalDependencies` to link to your local clone of this repository (don't
   forget to `yarn` after):

   ```json
   "@beeper/platform-imessage": "link:../platform-imessage",
   ```

   (Running `yarn link ../platform-imessage` (or similar) doesn't work at the
   moment.)

3. **In `beeper-desktop-new`,** run:

   ```
   bun _ symlink-platform-binaries
   ```

   This symlinks `app/build/platform-imessage` to
   `node_modules/@beeper/platform-imessage` (both of these paths are relative to
   the desktop repo). But because we re-pointed the dependency above, it
   ultimately ends up pointing to your local clone of `platform-imessage`.

   (`bun _ copy-platform-binaries`, alternatively spelled
   `bun copy:platform-binaries`, copies instead of symlinking.)

### Building and Using

<!-- prettier-ignore-->
> [!IMPORTANT]
> Adding the account might crash at first
> ([DESK-5684](https://linear.app/beeper/issue/DESK-5684/mattwondra-app-crashed-while-adding-local-imessage)).
> However, subsequent attempts should succeed.

<!-- prettier-ignore -->
> [!IMPORTANT]
> When adding a local iMessage account to Beeper, you'll be prompted for
> several permissions. One of them is "Accessibility", which is done in a
> System Settings window that the app opens for you. **In development, grant
> this permission to your terminal program, text editor, or wherever you're
> running `yarn dev` from instead of Beeper or Electron.**

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
> * Try rebooting. <sub>(ol' reliable)</sub>

4. **If you're only interested in running from source,** perform a one-shot
   build of everything ([RustServer], [AppleScriptServer], [SwiftServer], [the
   TypeScript code][platformapi-subclass], and the SCSS) **(in this
   repository)**:

   ```
   bun build-binaries
   ```

   Upon success, native binaries and CSS should be present in `./binaries`.
   Because of the linking that occurred above, `app/build/platform-imessage` (in
   `beeper-desktop-new`) should point there.

5. **If you're interested in developing `platform-imessage`**, then run this
   command **in this repository**:

   ```sh
   bun dev
   ```

   This command watches for changes in Swift, CSS, or JS files, continuously
   rebuilding as necessary.

   `--debug` is automatically passed to `yarn build-swift`. This disables
   compiler optimizations, symbol stripping, and it only builds for your current
   architecture. Additional parameters that may be passed to `build-swift` (and
   therefore `dev`):

   - `--no-spaces` defines the `NO_SPACES` compilation condition
     (`#if NO_SPACES`) for the Swift code, which disables
     [the behaviors involved in attempting to hide the Messages app](https://github.com/beeper/platform-imessage/blob/c670583e642d7a4df45f9a9d499720768d454370/src/SwiftServer/Sources/SwiftServer/SpacesWindowHidingManager.swift#L108)
     in an invalid Mission Control space. This is useful for testing and
     debugging as it keeps the Messages app visible.
   - `--clean` will purge build artifacts before building.
   - `--all-archs` forces the building of all architectures (`arm64` and `x64`).

   For CSS changes to take effect, you may need to re-copy platform binaries in
   `beeper-desktop-new` (the CSS file is in the "binaries" directory):

   ```
   yarn copy:platform-binaries
   ```

6. At this point, you should be able to simultaneously run `yarn dev`/`bun dev`
   in [`beeper-desktop-new`][beeper-desktop-new] and add a local iMessage
   account to your development instance of Beeper Desktop.

   If you have an instance of `yarn dev`/`bun dev` already running for desktop,
   you'll have to interrupt the command and re-run.

</details>

## Logs

Logs are persisted to:

- `~/Library/Application Support/BeeperTexts/logs/platform-imessage.log`

<!-- prettier-ignore -->
> [!IMPORTANT]
> This path respects `BEEPER_PROFILE`, so the directory name is `BeeperTexts-dev`
> instead of `BeeperTexts` in development, and so on.

Keep in mind that the previous logging location was:

- `~/Library/Application Support/jack/platform-imessage.log`

It's worth checking this path if you can't locate a log at the aforementioned
path in `BeeperTexts`, because for a short period of time, this path was being
used with Beeper Desktop.

---

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
bun run build-swift --debug --watch

# for shipping to prod:
bun run build-swift
```

### Testing

```sh
node src/SwiftServer/test-script.js
electron src/SwiftServer/test-script.js
```
