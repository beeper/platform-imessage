#!/usr/bin/env bash

set -euo pipefail

# Publish to GitHub Releases only on tag builds. Non-tag builds (PRs,
# main) still produce a signed+notarized tarball — uploaded as a
# Buildkite artifact — for download/testing.
if [ -n "${BUILDKITE_TAG:-}" ]; then
  tag="$BUILDKITE_TAG"
  version="${tag#v}"
  publish=true
else
  base_version="$(python3 -c 'import json; print(json.load(open("package.json"))["version"])')"
  short_sha="${BUILDKITE_COMMIT:0:7}"
  version="${base_version}-${short_sha}"
  publish=false
fi

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

if ! "$publish"; then
  echo "--- :information_source: skipping GitHub release publish (no tag); tarball stashed as Buildkite artifact"
  exit 0
fi

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
