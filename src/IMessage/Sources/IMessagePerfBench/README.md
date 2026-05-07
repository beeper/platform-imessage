# IMessagePerfBench

Backend-agnostic performance harness for the iMessage read paths.

The benchmark intentionally calls public `IMDatabase` methods and public
`PlatformAPI` methods. It does not import GRDB, SQLiteData, or any other
storage implementation directly, so a branch can swap the internals behind
`IMDatabase` and keep using the same benchmark.

Run through the repo wrapper for terminal tables:

```sh
yarn perf:imessage
```

Useful variants:

```sh
yarn perf:imessage --sql-only --iterations 20
yarn perf:imessage --api-only --api-thread-samples 10
yarn perf:imessage --with-parity --max-chats 5 --message-limit 20
yarn perf:imessage --json
```
