#!/usr/bin/env sh

SDKROOT=$(xcrun -sdk macosx11.0 --show-sdk-path) \
MACOSX_DEPLOYMENT_TARGET=$(xcrun -sdk macosx11.0 --show-sdk-platform-version) \
cargo build --manifest-path src/RustServer/Cargo.toml --release --target=aarch64-apple-darwin

cargo build --manifest-path src/RustServer/Cargo.toml --release

FILE_PATH_X64=src/RustServer/target/release/rust_server
FILE_PATH_ARM64=src/RustServer/target/aarch64-apple-darwin/release/rust_server

ls -lah $FILE_PATH_X64
strip $FILE_PATH_X64
ls -lah $FILE_PATH_X64

ls -lah $FILE_PATH_ARM64
strip $FILE_PATH_ARM64
ls -lah $FILE_PATH_ARM64

cp $FILE_PATH_ARM64 binaries/rust_server_arm64_macos
cp $FILE_PATH_X64 binaries/rust_server_x64_macos
