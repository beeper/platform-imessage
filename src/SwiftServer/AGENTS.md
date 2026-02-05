# AGENTS.md - SwiftServer (platform-imessage/src/SwiftServer)

This doc focuses on how SwiftServer automates Messages.app: deep links,
conversation selection, replying, and related flows.

## Entry points and bridging

- Swift module exports are registered in
  `platform-imessage/src/SwiftServer/Sources/SwiftServer/SwiftServer.swift` via
  `#NodeModule`.
- JS loads the native addon from
  `platform-imessage/src/SwiftServer/lib/index.ts` (loads
  `binaries/darwin-*/SwiftServer.node`).
- `MessagesControllerWrapper` (`.../MessagesControllerWrapper.swift`) is the
  Node-facing class. It:
  - serializes calls on a dedicated queue (`PassivelyAwareDispatchQueue`).
  - bridges Swift async work to JS via `NodeAsyncQueue` and `NodePromise`.
  - owns a `MessagesController` instance and exposes methods like
    `sendMessage`, `setReaction`, `editMessage`, `undoSend`, etc.

## Deep link opening

Core pieces:
- `MessagesDeepLink` (`.../MessagesDeepLink.swift`) builds
  `imessage://open?...` URLs:
  - `address` / `addresses` for new chats
  - `groupid` for group chats
  - `message-guid` (optionally `overlay=1`) for targeting a message
- `MessagesApplication.sendDeepLink` (`.../MessagesApplication.swift`) sends a
  kAEGetURL Apple Event to a running Messages instance.
- `MessagesApplication.openDeepLink` sends the event to the controlled
  instance (public or puppet), and may activate or hide the window afterward.
- `MessagesController` wires `elements.openDeepLink` to
  `MessagesApplication.openDeepLink`, so all element lookups and recovery paths
  can open deep links through the correct instance.

Debugging:
- Deep link events can be recorded and visualized (see
  `.../UI/DeepLinkDebug*`).

## Selecting a conversation (thread)

The basic flow:
- `openThread(threadID)` in `MessagesController`:
  - opens the deep link for the thread.
  - calls `assertSelectedThread(threadID)` to verify the selection.

Selection verification (misfire prevention):
- Primary signal is the Messages defaults key
  `CKLastSelectedItemIdentifier` accessed via
  `Defaults.getSelectedThreadID()` in `.../Defaults.swift`.
  - This value is checked against the target thread ID, including contact
    equivalence for single chats.
- Fallbacks are chosen by `DefaultsKeys.misfirePreventionFallbackStrategy`:
  - `title-prediction`: predicts the Messages window title using DB + Contacts
    in `MessagesController+Window Title Prediction.swift`.
  - `focus-waiter` / `layout-waiter`: uses `LifecycleObserver` timestamps to
    confirm a focus or layout change after selection.

Making the thread cell accessible:
- `scrollAndGetSelectedThreadCell(threadID)` makes sure the selected thread
  cell is visible, using `selectNextThreadAndScroll()` and then re-opening the
  deep link if needed.
- Thread actions (mute, delete, mark read, etc.) use the selected thread cell
  and trigger its AX actions by name.

Relevant files:
- `.../MessagesController.swift` (openThread, assertSelectedThread,
  scrollAndGetSelectedThreadCell)
- `.../Defaults.swift` (read selected thread ID)
- `.../LifecycleObserver.swift` (layout/focus change timestamps)
- `.../MessagesController+Window Title Prediction.swift`

## Replying and targeting a message

Message targeting is based on a `MessageCell` struct coming from JS:
- `messageGUID`: the message GUID for deep linking.
- `overlay`: whether reply transcript overlay should be used.
- `offset`, `cellID`, `cellRole`: used to find the exact cell in the transcript.

`withMessageCell(...)` in `MessagesController`:
- Opens a message deep link (overlay aware).
- Ensures the correct thread is selected.
- If overlay is requested:
  - optionally opens the reply transcript via menu on macOS 26+
  - waits until the reply transcript is visible.
- Finds the target cell either in the main transcript or reply transcript
  and validates `cellID` / `cellRole` when provided.

Reply paths:
- Non-overlay reply (`sendReplyWithoutOverlay`):
  - triggers the message action `.reply` on the target cell.
  - fills the message body field and sends.
- Overlay reply (quoted message):
  - uses `MessagesDeepLink.message(..., overlay: true)` and the reply transcript
    flow inside `withMessageCell`.

Relevant files:
- `.../MessagesController.swift` (withMessageCell, sendReplyWithoutOverlay)
- `.../MessagesAppElements.swift` (transcript view, reply transcript view)

## Sending a message (end-to-end)

`MessagesController.sendMessage(...)` handles several cases:
1. OSA fast path (AppleScript) for simple sends when possible:
   - Used for plain text without mentions/links, or for files on supported OSes.
   - Falls back to UI automation if it fails.
2. Deep link selection:
   - `message` deep link for quoted replies.
   - `thread` deep link for an existing chat.
   - `addresses` deep link for a new chat.
3. Automation:
   - `prepareForAutomation()` makes the app automatable and acquires the
     activity lock.
   - `withActivation(openBefore: url)` opens the deep link and runs the action
     while the app is visible/automatable.
4. Compose:
   - If the compose cell is selected, it sleeps briefly to allow address
     resolution.
   - Fills `messageBodyField` and calls `sendMessageInField()`.

`sendMessageInField()`:
- Focuses the message field and presses Return.
- Verifies the send by re-reading the field value (retries) and avoids
  bubbling errors that could cause duplicate sends.

Relevant files:
- `.../MessagesController.swift` (sendMessage, sendMessageInField, OSA path)
- `.../MessagesAppElements.swift` (messageBodyField lookup)
- `.../OSA.swift` (AppleScript fast path)

## Other common actions ("and more")

Reactions:
- `setReaction(...)` uses the message `.react` action and then either the
  Tapback picker or the custom emoji picker on macOS 15+.

Edit:
- `editMessage(...)` triggers `.edit` (or menu fallback), replaces the text,
  and confirms with Return.

Undo send:
- `undoSend(...)` triggers `.undoSend` (macOS 13+).

Typing indicator:
- `sendTypingStatus(...)` opens a deep link with `body=" "` to start typing
  (space is special-cased by Messages), and clears the field to stop typing.

Thread actions:
- `toggleThreadRead`, `muteThread`, and `deleteThread` all:
  - open the thread deep link
  - assert selection
  - trigger the thread cell action by its localized name

## Supporting components

- `MessagesAppElements` (`.../MessagesAppElements.swift`):
  - resolves AX elements (conversation list, selected thread, transcript view,
    reply transcript view, message body field) with retries and caching.
- `WindowCoordinator` (`.../WindowCoordinator.swift`):
  - manages window visibility and restores state after automation.
- `LifecycleObserver` (`.../LifecycleObserver.swift`):
  - observes AX events for focus/layout changes, used by misfire prevention.
