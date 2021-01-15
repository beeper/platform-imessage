#!/usr/bin/env sh

SDKROOT=$(xcrun -sdk macosx11.0 --show-sdk-path) \
MACOSX_DEPLOYMENT_TARGET=$(xcrun -sdk macosx11.0 --show-sdk-platform-version) \
cargo build --manifest-path src/RustServer/Cargo.toml --release --target=aarch64-apple-darwin

cargo build --manifest-path src/RustServer/Cargo.toml --release

FILE_PATH_X64=src/RustServer/target/release/rust_server
FILE_PATH_ARM64=src/RustServer/target/aarch64-apple-darwin/release/rust_server

# ls -lah $FILE_PATH_X64
# strip $FILE_PATH_X64
# ls -lah $FILE_PATH_X64

# ls -lah $FILE_PATH_ARM64
# strip $FILE_PATH_ARM64
# ls -lah $FILE_PATH_ARM64

lipo -create $FILE_PATH_ARM64 $FILE_PATH_X64 -output binaries/rust_server

ls -lah binaries/rust_server
strip binaries/rust_server
ls -lah binaries/rust_server
