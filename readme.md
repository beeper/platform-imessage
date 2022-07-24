# platform-imessage

This repo uses [Git LFS](https://git-lfs.github.com/) to host compiled binaries.

## SwiftServer

SwiftServer exposes Swift functions to JS via NAPI/[node-swift](https://github.com/kabiroberai/node-swift) and handles all invocation of native Apple methods.

### AX edge cases

* iMessage has separate threads for each address/sender ID (email or phone #) but transparently merges threads belonging to the same contact in the UI. Texts app shows separate threads and performs no merging. Imagine if we had two threads, stevejobs@apple.com and sjobs@apple.com. When calling a deep link for either, only one of them would actually select the thread in the sidebar, the other would create a new compose cell. It's likely the last contacted address that doesn't create a compose cell.  
![Compose cell](images/compose-cell.png)

* `MessagesController.pasteFileInBodyField`: On Big Sur, using `pasteboard.setString(fileURL.relativeString, forType: .fileURL)` doesn't paste the file itself but a link. Monterey has intended behavior.
