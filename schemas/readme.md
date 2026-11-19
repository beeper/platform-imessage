# chat.db schemas

The schema of a freshly created `~/Library/Messages/chat.db`, per macOS release, as `sqlite3`'s `.schema --indent --nosys` output with objects in a stable order (tables, indexes, triggers; by name). Each file loads as is into an empty database.

Each file is produced by the release's own `IMDPersistence.framework`: its database initializer is run against an empty database, so the result includes whatever that build creates at first launch, feature flags included.

## Dumping

```sh
./schemas/dump.sh 24G90            # a build, a version, a restore image URL, or several separated by commas
./schemas/dump.sh --all            # every "ipsw" release in loctables/sources.json without a dump
```

Requires [ipswrun](https://github.com/KishanBagaria/ipswrun) (on `PATH` or as `IPSWRUN_BIN`) and the Xcode command line tools. No Mac or VM running the release is involved.

`--output` chooses another directory; `--cache`, `--stream-compressed` and `--trace` are passed on to ipswrun. macOS 13 and 14 need `--stream-compressed`, which downloads 3.6–4.5 GB per release.

The script builds `runner.c`, which loads `IMDPersistence` and asks it for the shared database. It runs it twice per release under ipswrun, each time in a fresh home, and requires both runs to create the same `(type, name, sql)` set.

## Checks worth repeating after changing the runner or ipswrun

- On a Mac whose build has a restore image, the dump must equal what the installed framework creates natively (verified for 27.2.1 / 26B131).
- Comparing with a database Messages has used: platform-imessage adds `message_idx_date_read` and `message_idx_date_edited`, and SQLite adds `sqlite_stat1` after `ANALYZE`; none of the three is part of a fresh schema. A database upgraded in place also differs from a fresh one: columns added by migrations sit in migration order and carry explicit defaults.

## Not covered

Releases that only exist as OTA updates.
