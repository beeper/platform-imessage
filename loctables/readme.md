# Loctables

Dump Chat/IM framework and accessibility bundle loctables as formatted JSON.

## Local macOS

```sh
./loctables/dump.sh
```

## Remote macOS IPSW

Requires [KishanBagaria/ipsw](https://github.com/KishanBagaria/ipsw) with ranged extraction support. Use `IPSW_BIN` if the binary isn’t on PATH.

```sh
IPSW_BIN=/path/to/ipsw ./loctables/dump.sh --ipsw latest
IPSW_BIN=/path/to/ipsw ./loctables/dump.sh --ipsw 'https://…/UniversalMac_…_Restore.ipsw'
```

Extraction uses HTTP byte ranges without downloading or mounting the entire disk image. Set `IPSW_DEVICE` to override the default `Macmini9,1` device selector.

## Output

Dumps are saved under `loctables/<version>-<build>/`. Use `--output` to choose another directory:

```sh
./loctables/dump.sh --ipsw latest --output /tmp/loctables
```

Both modes require macOS `plutil` and the repository’s Yarn/Prettier installation. IMAP resources are excluded.

[sources.json](sources.json) lists the collected releases and their Apple download URLs. The checked macOS 11/12 releases contained no matching loctables.
