#!/usr/bin/env bash
set -eux

here="$(dirname "${BASH_SOURCE[0]}")"
repo="$here/../../"
export MACOSX_DEPLOYMENT_TARGET=10.12

build_arch() {
  printf "\033[1m\033[34mBuilding RustServer for architecture \"%s\", binary subfolder architecture \"%s\"\033[0m\n" "$1" "$2"
  cargo build --manifest-path "$here/RustServer/Cargo.toml" --release --target="$1"

  built_path="$here/RustServer/target/$1/release/librust_server.dylib"
  out_path="$repo/binaries/darwin-$2/rust-server.node"

  ls -lah "${built_path}"
  strip -ur "${built_path}" -o "${out_path}"
  codesign -fs - "${out_path}"
}

build_arch aarch64-apple-darwin arm64
build_arch x86_64-apple-darwin x64
