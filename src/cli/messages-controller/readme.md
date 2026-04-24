# messages-controller-cli

```sh
yarn build:swift --debug --standalone
yarn build:messages-controller-cli
yarn messages-controller-cli
```

This starts an interactive `imsg>` prompt that lets you call `MessagesController` methods directly.

Or run a single command without entering the REPL:

```sh
yarn messages-controller-cli "sendMessage any;-;sjobs@apple.com hello-world"
yarn messages-controller-cli "editMessage any;-;sjobs@apple.com last-message hello-world"
```

Other REPL commands:
```sh
imsg> undoSend any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678
imsg> setReaction any;-;sjobs@apple.com last-message heart true
imsg> toggleThreadRead any;-;sjobs@apple.com true
imsg> muteThread any;-;sjobs@apple.com true
imsg> notifyAnyway any;-;sjobs@apple.com
imsg> sendTypingStatus any;-;sjobs@apple.com true
imsg> watch any;-;sjobs@apple.com
```

Use `_` for arguments that should be passed through as nil/undefined. `last-message` resolves to the latest message ID in that thread.

The REPL currently splits command arguments on spaces, so message text containing spaces is not preserved correctly yet.

For local testing against the higher-level `PlatformAPI` surface, see the root (readme.md)[../../../readme.md].
