#!/usr/bin/env sh

cd src/AppleScriptServer

xcodebuild -scheme AppleScriptServer -configuration Release SYMROOT='./' CODE_SIGN_IDENTITY="" build

ls -lah Release/AppleScriptServer
strip Release/AppleScriptServer
ls -lah Release/AppleScriptServer

lipo Release/AppleScriptServer -thin x86_64 -output ../../binaries/darwin-x64/AppleScriptServer
lipo Release/AppleScriptServer -thin arm64 -output ../../binaries/darwin-arm64/AppleScriptServer
