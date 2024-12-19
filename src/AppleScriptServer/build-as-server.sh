#!/usr/bin/env sh

cd src/AppleScriptServer

xcodebuild -scheme AppleScriptServer -configuration Release SYMROOT='./' build

ls -lah Release/AppleScriptServer
strip Release/AppleScriptServer
codesign -f -s - Release/AppleScriptServer
ls -lah Release/AppleScriptServer

mkdir -p ../../binaries/darwin-{x64,arm64}
lipo Release/AppleScriptServer -thin x86_64 -output ../../binaries/darwin-x64/AppleScriptServer
lipo Release/AppleScriptServer -thin arm64 -output ../../binaries/darwin-arm64/AppleScriptServer
