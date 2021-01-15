#!/usr/bin/env sh

cd src/AppleScriptServer

xcodebuild -scheme AppleScriptServer -configuration Release SYMROOT='./' CODE_SIGN_IDENTITY="" build

ls -lah Release/AppleScriptServer
strip Release/AppleScriptServer
ls -lah Release/AppleScriptServer

cp Release/AppleScriptServer ../../binaries/
