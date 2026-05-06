#!/usr/bin/env bash

set -euo pipefail

if [ -z "${BUILDKITE_TAG:-}" ]; then
  printf >&2 "expected BUILDKITE_TAG to be set; this script only runs for tag builds\n"
  exit 1
fi

tag="$BUILDKITE_TAG"
version="${tag#v}"
asset_name="imessage-cli-${version}-macos-universal.tar.gz"

echo "--- :hammer_and_wrench: build, sign, notarize"
./scripts/sign-and-notarize-cli

binary=".build/universal/release/imessage-cli"
if [ ! -f "$binary" ]; then
  printf >&2 "expected signed binary at %s\n" "$binary"
  exit 1
fi

echo "--- :package: tarball + sha256"
# Write to dist/ (gitignored) so the pipeline's `artifact_paths` glob can pick
# the files up even if a later step fails — no need for explicit uploads here.
rm -rf dist
mkdir -p dist
cp "$binary" "dist/imessage-cli"
chmod +x "dist/imessage-cli"
tar -czf "dist/$asset_name" -C dist imessage-cli
( cd dist && shasum -a 256 "$asset_name" > "$asset_name.sha256" )

echo "--- :rocket: publish to GitHub release"
# Idempotent: create the release if missing, then upload with --clobber so re-runs replace
if ! gh release view "$tag" --repo beeper/platform-imessage >/dev/null 2>&1; then
  gh release create "$tag" \
    --repo beeper/platform-imessage \
    --title "iMessage CLI $version" \
    --notes "macOS iMessage CLI release for @beeper/platform-imessage $version."
fi

gh release upload "$tag" "dist/$asset_name" "dist/$asset_name.sha256" \
  --repo beeper/platform-imessage \
  --clobber
