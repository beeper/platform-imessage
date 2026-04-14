# IMDatabaseTestBench

Test program for [the `IMDatabase` library](../IMDatabase).

Because Full Disk Access is needed to read Messages data, a command like this
may be used to iterate on the program:

```
xcrun swift build --product IMDatabaseTestBench \
  && codesign -f -vvv --sign "Apple Development: $MY_NAME" --timestamp .build/debug/IMDatabaseTestBench \
  && ./.build/debug/IMDatabaseTestBench
```

## Poll Benchmark

To benchmark the hot unread-state query used by SwiftServer polling without
running the Electron app:

```
./scripts/poller-benchmark --duration 30 --concurrency 1
```

The benchmark opens `~/Library/Messages/chat.db` read-only through `IMDatabase`
and repeatedly runs the same `chatStates()` query that the poller executes when
the Messages database changes. It prints per-cycle latency, throughput, and
process CPU usage. The wrapper builds the release test-bench binary on first
run; set `BUILD=1` to force a rebuild or `CONFIGURATION=debug` to use a debug
build while iterating.

Useful variants:

```
# Simulate the poller's unread query plus its message-update query.
./scripts/poller-benchmark --duration 30 --include-updates

# Stress the query harder with independent read-only connections.
./scripts/poller-benchmark --duration 30 --concurrency 4

# Mimic very frequent debounced database change events instead of a tight loop.
./scripts/poller-benchmark --duration 30 --interval-ms 25
```
