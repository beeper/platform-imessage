# Loctables

Dump Chat/IM framework and accessibility bundle loctables as formatted JSON. Both local and IPSW dumps also include the Privacy & Security extension’s Localizable table when present. The `ACCESSIBILITY` entry gives the permission label for each language.

## Local macOS

```sh
./loctables/dump.sh
```

## Remote macOS IPSW

Requires [ipsw](https://github.com/blacktop/ipsw) v3.1.750+: `brew install ipsw` (or `brew upgrade ipsw`). Set `IPSW_BIN` to use a binary that isn’t on PATH.

```sh
./loctables/dump.sh --ipsw latest
./loctables/dump.sh --ipsw 'https://…/UniversalMac_…_Restore.ipsw'
```

Extraction uses HTTP byte ranges without downloading or mounting the entire disk image. Set `IPSW_DEVICE` to override the default `Macmini9,1` device selector.

## Output

Dumps are saved under `loctables/<version>-<build>/`. Use `--output` to choose another directory:

```sh
./loctables/dump.sh --ipsw latest --output /tmp/loctables
```

Both modes require macOS `plutil` and the repository’s Yarn/Prettier installation. IMAP resources are excluded.

[sources.json](sources.json) lists the collected releases and their Apple download URLs. The checked macOS 11/12 releases contained no matching loctables.
