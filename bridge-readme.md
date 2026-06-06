# mautrix-imessage bridgev2

This repo includes a bridgev2 Matrix bridge entrypoint at `cmd/mautrix-imessage`.

The bridge is integrated with the Swift iMessage runtime through `IMessageBridgeKit`, a Swift dynamic library with a C ABI. It does not shell out to `imessage-cli`.

## Build

```sh
swift build --product IMessageBridgeKit
swift_bin="$(swift build --show-bin-path)"
CGO_LDFLAGS="-L${swift_bin} -Wl,-rpath,${swift_bin}" \
  go build -tags nocrypto ./cmd/mautrix-imessage
```

The `nocrypto` tag avoids linking mautrix's optional libolm dependency while still keeping cgo enabled for the Swift bridge library.

The bridge currently supports local-login, startup chat/message sync, live state-sync events, Matrix text/file sends, replies, edits, unsend, reactions, read receipts, and typing.

It must run on macOS with the usual platform-imessage permissions for Messages data and UI automation.
