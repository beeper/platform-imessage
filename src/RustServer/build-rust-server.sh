#!/usr/bin/env sh

cargo build --manifest-path src/RustServer/Cargo.toml --release --target=aarch64-apple-darwin

cargo build --manifest-path src/RustServer/Cargo.toml --release

FILE_PATH_X64=src/RustServer/target/release/librust_server.dylib
FILE_PATH_ARM64=src/RustServer/target/aarch64-apple-darwin/release/librust_server.dylib

ls -lah $FILE_PATH_X64
ls -lah $FILE_PATH_ARM64

cp $FILE_PATH_X64 binaries/x64.node
cp $FILE_PATH_ARM64 binaries/arm64.node
