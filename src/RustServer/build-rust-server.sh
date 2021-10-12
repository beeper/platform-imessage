#!/usr/bin/env sh

function build_arch {
    cargo build --manifest-path src/RustServer/Cargo.toml --release --target="$1"
    local built_path="src/RustServer/target/$1/release/librust_server.dylib"
    local out_path="binaries/macos-$2/rust-server.node"
    ls -lah "${built_path}"
    strip -ur "${built_path}" -o "${out_path}"
    codesign -fs - "${out_path}"
}

build_arch aarch64-apple-darwin arm64
build_arch x86_64-apple-darwin x64
