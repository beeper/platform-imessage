# platform-imessage

This repo uses [Git LFS](https://git-lfs.github.com/) to host compiled binaries.

## SwiftServer

SwiftServer exposes Swift functions to JS via NAPI/[node-swift](https://github.com/kabiroberai/node-swift) and handles all invocation of native Apple methods.

### Quirks

* Transparent thread merging: iMessage has separate threads for each address/sender ID (email or phone #) but transparently merges threads belonging to the same contact in the UI. Texts app shows separate threads and performs no merging. Imagine if we had two threads, stevejobs@apple.com and sjobs@apple.com. When calling a deep link to select either thread, sometimes it'll select the thread in the sidebar, other times it'd create a new compose cell. The logic is unknown.  
![Compose cell](images/compose-cell.png)

* `MessagesController.pasteFileInBodyField`: On Big Sur, using `pasteboard.setString(fileURL.relativeString, forType: .fileURL)` doesn't paste the file itself but a link. Monterey has intended behavior.

* `elements.selectedThreadCell` is nil after pin/unpin because no cells are selected. `imessage://open?message-guid=` will not select the thread in sidebar (`elements.selectedThreadCell == nil`) if it's already open but `imessage://open?address=` will.

* After `elements.searchField` was clicked: `elements.conversationsList` will be nil, selected item in sidebar will not always be reflective of the messages list, calling a deep link will not update sidebar but only the messages list, `CKLastSelectedItemIdentifier` won't be updated.
