# Loctables

Dump macOS Chat/IM and Privacy & Security localization tables to `loctables/<version>-<build>/` as JSON.

Run on macOS with Python 3.9+ and the repo’s Yarn dependencies installed. Remote dumps also require [ipsw v3.1.750+](https://github.com/blacktop/ipsw).

```sh
./loctables/dump.sh                 # Installed macOS
./loctables/dump.sh --ipsw latest   # Latest IPSW, or pass an IPSW URL
./loctables/dump.sh --all           # Every release in sources.json
```

Check a full rebuild against Git with

```sh
git diff --exit-code HEAD -- ':(glob)loctables/*/*.json'
```
